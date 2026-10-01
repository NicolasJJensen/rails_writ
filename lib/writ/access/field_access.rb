# frozen_string_literal: true

module Writ
  class Access
    module FieldAccess
      def readable_fields(context:, record:)
        fields_for(context: context, action: :read, record: record)
      end

      def writable_fields(context:, record:, action: :update)
        fields_for(context: context, action: action, record: record)
      end

      def input_fields(context:, record:, action:)
        validate_action!(action)
        model = record.is_a?(Class) ? record : record.class
        validate_model!(model)
        return fields_for(context: context, action: action, record: record) if record.is_a?(ActiveRecord::Base) && record.persisted?

        unless record.is_a?(Class) || (record.is_a?(ActiveRecord::Base) && record.new_record? && action.to_s == 'create')
          raise ArgumentError, 'Input fields require a model class, persisted record, or new record with action create'
        end

        authorization_model = Configuration.authorization_model_for(model)
        prepared = prepare_permissions(context, action, authorization_model, includes: [:role])
        # Candidate fields must be available before the attributes needed by proposed validators are assigned.
        resolve_fields(context, action, record, authorization_model, prepared.valid.map(&:role).uniq)
      end

      def normalize_field_names(record:, fields:)
        model = record.is_a?(Class) ? record : record.class
        Array(fields).map do |field|
          name = field.to_s.sub(/\(\d+[if]\)\z/, '')
          model.attribute_aliases.fetch(name, name)
        end.uniq
      end

      def fields_for(context:, action:, record:)
        validate_action!(action)
        model = record.is_a?(Class) ? record : record.class
        validate_model!(model)
        # Persisted records use the role-grouped path so alternative grants on one role
        # share a membership query; classes and proposed records need their own semantics.
        if record.is_a?(ActiveRecord::Base) && record.persisted?
          return fields_for_many(context: context, action: action, records: [record]).fetch(record)
        end

        authorization_model = Configuration.authorization_model_for(model)
        prepared = prepare_permissions(context, action, authorization_model, includes: [:role])
        permissions = prepared.valid
        return resolve_fields(context, action, record, authorization_model, permissions.map(&:role).uniq) if record.is_a?(Class)

        if record.is_a?(ActiveRecord::Base) && record.new_record? && action.to_s == 'create'
          preflight_proposed_matchers!(permissions, model, authorization_model)
        end
        matching = permissions.select do |permission|
          action.to_s == 'create' && proposed_grant_errors(context, record, permission, model, authorization_model,
                                                          normalized_arguments: prepared.normalized_arguments).empty?
        end
        if record.is_a?(ActiveRecord::Base) && record.new_record? && action.to_s == 'create' && matching.any?
          matching = [] unless run_action_validators(context, record, :create, authorization_model).empty?
        end
        resolve_fields(context, action, record, authorization_model, matching.map(&:role).uniq)
      end

      # One metadata load per call and one membership query per contributing role.
      # Records are already selected by the host; batch decisions never cache across calls.
      def fields_for_many(context:, action:, records:)
        validate_action!(action)
        records = records.to_a
        return {} if records.empty?
        unless records.all? { |record| record.is_a?(ActiveRecord::Base) && record.persisted? }
          raise ArgumentError, 'Batch field decisions require persisted ActiveRecord records'
        end
        groups = records.group_by(&:class).map do |model, group|
          [model, Configuration.authorization_model_for(model), group]
        end
        authorization_models = groups.map { |(_, authorization_model, _)| authorization_model }.uniq
        unless authorization_models.one?
          raise ArgumentError, 'Batch records must have the same model or resolve to one authorization model'
        end
        authorization_model = authorization_models.first
        prepared = prepare_permissions(context, action, authorization_model, includes: [:role])
        permissions_by_role = prepared.valid.group_by(&:role)
        groups.flat_map do |model, authorization_model, group|
          pk = primary_key!(model)
          ids = group.map { |record| record.public_send(pk) }
          raise ArgumentError, 'Batch records must include their primary key' if ids.any?(&:nil?)
          roles_by_id = Hash.new { |hash, key| hash[key] = [] }
          permissions_by_role.each do |role, permissions|
            membership = permission_membership(context, model, authorization_model, prepared, permissions: permissions)
            ScopeEvaluator.strip_ordering_and_limits(membership.where(pk => ids))
                          .distinct.pluck(pk).each { |id| roles_by_id[id] << role }
          end
          group.map do |record|
            [record, resolve_fields(context, action, record, authorization_model, roles_by_id[record.public_send(pk)])]
          end
        end.to_h
      end

      private

      def resolve_fields(context, action, record, model, roles)
        return [] if roles.empty?
        fields = []
        roles.each do |role|
          value = (role.accessible_fields || {}).fetch(model.name) { Configuration.field_default }
          value = value.fetch(action.to_s) { Configuration.field_default } if value.is_a?(Hash)
          if value.nil? || value == :all
            fields = :all
            break
          end
          fields |= value.map(&:to_s)
        end
        fields = apply_field_resolvers(context, action, record, model, fields)
        unless fields == :all || (fields.is_a?(Array) && fields.all? { |field| field.is_a?(String) || field.is_a?(Symbol) })
          raise ConfigurationError, 'Field resolver must return :all or an array of field names'
        end
        fields == :all ? :all : fields.map(&:to_s).uniq
      end

      def apply_field_resolvers(context, action, record, model, fields)
        registry = Configuration.registry
        global = registry.field_resolvers_for(model_name: nil)
        local = registry.field_resolvers_for(model_name: model.name)
        resolvers = if local.any?
          local.any? { |definition| definition[:include_global] } ? global + local : local
        else
          global
        end
        resolvers.reduce(fields) do |current, definition|
          callable = definition.is_a?(Hash) ? definition[:callable] : definition
          callable.call(context: context, action: action.to_sym, record: record, fields: current.deep_dup)
        end
      end
    end
  end
end
