# frozen_string_literal: true

module Writ
  class Access
    ProposalResult = Struct.new(:record, :result, keyword_init: true) do
      def initialize(record:, result:)
        super
        freeze
      end
    end

    module Proposal
      ATTRIBUTES_NOT_PROVIDED = Object.new.freeze
      private_constant :ATTRIBUTES_NOT_PROVIDED

      def propose(subject:, context:, action: nil, attributes: ATTRIBUTES_NOT_PROVIDED)
        unless subject.is_a?(ActiveRecord::Base)
          raise ArgumentError, 'propose requires an ActiveRecord record'
        end
        raise ArgumentError, 'propose requires a record that has not been destroyed' if subject.destroyed?

        action ||= subject.new_record? ? :create : :update
        validate_action!(action)
        supplied = !attributes.equal?(ATTRIBUTES_NOT_PROVIDED)
        attributes = subject.send(:sanitize_for_mass_assignment, attributes) if supplied
        submitted_fields = supplied ? attributes.keys : subject.changed_attribute_names_to_save
        column = subject.class.inheritance_column
        type_key = if supplied && column && subject.has_attribute?(column)
          attributes.keys.reverse.find { |key| normalize_field_names(record: subject, fields: [key]) == [column] }
        end

        begin
          destination_model = if type_key
            proposed_sti_model(subject, value: attributes[type_key])
          else
            proposed_sti_model(subject)
          end
          source_model = subject.new_record? ? subject.class : proposed_sti_model(subject, saved: true)
        rescue ActiveRecord::SubclassNotFound, NameError
          subject.assign_attributes(type_key => attributes[type_key]) if type_key
          return invalid_sti_proposal(subject)
        end

        reject_pending_association_changes!(subject) if subject.class != destination_model
        candidate = subject.class == destination_model ? subject : cast_proposal(subject, destination_model)
        candidate.assign_attributes(attributes) if supplied
        begin
          return invalid_sti_proposal(candidate) unless proposed_sti_model(candidate) == candidate.class
        rescue ActiveRecord::SubclassNotFound, NameError
          return invalid_sti_proposal(candidate)
        end
        changed_type = subject.persisted? && column && candidate.has_attribute?(column) &&
                       candidate.will_save_change_to_attribute?(column)
        transition = source_model != destination_model || changed_type
        unless transition || subject.class != destination_model
          result = validation(subject: candidate, action: action, context: context, submitted_fields: submitted_fields)
          return ProposalResult.new(record: candidate, result: result)
        end

        if candidate.new_record?
          raise ArgumentError, 'validation requires action create for a new record' unless action.to_s == 'create'
        else
          raise ArgumentError, 'STI transitions require action update' unless action.to_s == 'update'

          validate_update_record!(candidate, allow_sti_change: true)
        end
        reject_pending_association_changes!(candidate)

        submitted_fields = (submitted_fields.map(&:to_s) + [subject.class.inheritance_column]).uniq if transition

        if subject.persisted?
          source = cast_proposal(subject, source_model, saved: true)
          unless source_model.where(primary_key!(source_model) => source.id).exists?
            return ProposalResult.new(record: candidate, result: CheckResult.new(allowed: false, reason: :scope_mismatch))
          end
          source_result = authorization(subject: source, action: action, context: context)
          return ProposalResult.new(record: candidate, result: source_result) unless source_result.allowed?

          source_result = proposal_field_check(context, action, source, submitted_fields)
          return ProposalResult.new(record: candidate, result: source_result) unless source_result.allowed?
        end

        validator_models = [destination_model]
        validator_models.unshift(source_model) unless subject.new_record?
        result = local_validation_result(context, action, candidate, submitted_fields: submitted_fields,
                                         field_mode: :proposed, validator_models: validator_models)
        ProposalResult.new(record: candidate, result: result)
      end

      private

      def proposed_sti_model(record, saved: false, value: ATTRIBUTES_NOT_PROVIDED)
        model = record.class
        column = model.inheritance_column
        return model unless column && model.column_names.include?(column)

        value = saved ? record.attribute_in_database(column) : record.public_send(column) if value.equal?(ATTRIBUTES_NOT_PROVIDED)
        target = value.blank? ? model.base_class : model.base_class.send(:find_sti_class, value)
        unless target.table_name == model.table_name && target.primary_key == model.primary_key &&
               target.inheritance_column == column
          raise ActiveRecord::SubclassNotFound, 'STI transitions must use the same table and inheritance column'
        end
        target
      end

      def invalid_sti_proposal(record)
        error = ErrorSnapshot.new(attribute: record.class.inheritance_column, type: :invalid,
                                  options: { message: 'must identify a type in the same inheritance hierarchy' })
        ProposalResult.new(record: record, result: CheckResult.new(allowed: false, reason: :invalid_sti_type, errors: [error]))
      end

      def proposal_field_check(context, action, record, submitted_fields)
        permitted = input_fields(context: context, record: record, action: action)
        forbidden = if permitted == :all
          []
        else
          normalize_field_names(record: record, fields: submitted_fields) - normalize_field_names(record: record, fields: permitted)
        end
        errors = forbidden.map do |field|
          ErrorSnapshot.new(attribute: field, type: :not_permitted, options: { message: 'is not permitted' })
        end
        CheckResult.new(allowed: errors.empty?, reason: errors.empty? ? :granted : :forbidden_fields, errors: errors)
      end

      def cast_proposal(record, model, saved: false)
        # ActiveRecord#becomes shares attributes and runs initialization callbacks. Neither is
        # appropriate for a proposal: it must retain its saved baseline without new host mutations.
        candidate = model.allocate
        record.instance_variables.each do |name|
          candidate.instance_variable_set(name, record.instance_variable_get(name))
        end
        model.define_attribute_methods
        candidate.instance_variable_set(:@attributes, proposal_attributes(record, model, saved: saved))
        candidate.instance_variable_set(:@mutations_from_database, nil)
        candidate.instance_variable_set(:@association_cache, {})
        candidate.instance_variable_set(:@aggregation_cache, {})
        unless saved
          record.changed_attribute_names_to_save.each { |field| candidate.send(:attribute_will_change!, field) }
        end

        candidate.instance_variable_set(:@errors, ActiveModel::Errors.new(candidate))
        owned = record.instance_variable_get(:@writ_applied_errors) || []
        copied_owned = []
        record.errors.each do |error|
          copy = candidate.errors.add(error.attribute, error.type, **error.options.deep_dup)
          copied_owned << copy if owned.any? { |previous| previous.equal?(error) }
        end
        candidate.instance_variable_set(:@writ_applied_errors, copied_owned)
        candidate.freeze if record.frozen?
        candidate
      end

      def proposal_attributes(record, model, saved: false)
        attributes = record.instance_variable_get(:@attributes).map do |original|
          attribute = copy_proposal_attribute(original)
          type = model.attribute_types[attribute.name]
          next attribute unless type && attribute.initialized? && (saved || !type.equal?(attribute.type))

          # Reinterpret the saved database value too; retaining a source enum's baseline
          # would otherwise invent a change merely because its Ruby representation differs.
          baseline = ActiveModel::Attribute.from_database(attribute.name, attribute.original_value_for_database, type)
          if !saved && (attribute.changed? || attribute.came_from_user?)
            value = attribute.changed_in_place? ? attribute.value : attribute.value_before_type_cast
            baseline.with_value_from_user(value)
          else
            baseline
          end
        end
        (model.attribute_names - attributes.keys - model.column_names).each do |name|
          attributes[name] = model.send(:_default_attributes)[name].deep_dup
        end
        attributes
      end

      def copy_proposal_attribute(attribute)
        copy = attribute.dup
        %i[@value @value_before_type_cast @value_for_database @user_provided_value @memoized_value_before_type_cast].each do |name|
          copy.instance_variable_set(name, attribute.instance_variable_get(name).deep_dup) if attribute.instance_variable_defined?(name)
        end
        original = attribute.instance_variable_get(:@original_attribute)
        copy.instance_variable_set(:@original_attribute, copy_proposal_attribute(original)) if original
        copy
      end
    end
  end
end
