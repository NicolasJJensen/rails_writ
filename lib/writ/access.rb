# frozen_string_literal: true

require_relative 'access/scope_evaluator'
require_relative 'access/condition_evaluator'
require_relative 'access/permission_query'
require_relative 'access/permission_preparation'
require_relative 'access/field_access'
require_relative 'access/proposed_check'
require_relative 'access/result'

module Writ
  # ActiveRecord authorization primitives. Presentation and serialization belong to the host.
  class Access
    PreparedPermissions = Struct.new(:source, :permissions, :valid, :denied, :evaluated, :normalized_arguments,
                                     keyword_init: true)
    extend FieldAccess
    extend ProposedCheck
    class << self
      def grant_available?(context:, action:, model:)
        validate_action!(action)
        validate_model!(model)
        authorization_model = Configuration.authorization_model_for(model)
        prepared = prepare_permissions(context, action, authorization_model, validate_scopes: false)
        prepared.valid.any?
      end

      def authorization(subject:, action:, context:)
        validate_action!(action)
        case subject
        when ActiveRecord::Base
          if subject.new_record?
            # A create predicate can establish grant authority without treating unsaved attributes as SQL membership.
            # Hosts validate proposed attributes explicitly before they save the record.
            return grant_availability_result(context, action, subject.class) if action.to_s == 'create'

            raise ArgumentError, 'authorization requires a persisted record'
          end

          saved_authorization_result(context, action, subject.class.where(primary_key!(subject.class) => subject.public_send(primary_key!(subject.class))))
        when ActiveRecord::Relation
          raise ArgumentError, 'grouped relations are not supported' if subject.group_values.any?

          normalized = ScopeEvaluator.strip_ordering_and_limits(subject)
          return CheckResult.new(allowed: true, reason: :granted) unless normalized.exists?

          saved_authorization_result(context, action, normalized)
        when Class
          validate_model!(subject)
          grant_availability_result(context, action, subject)
        when Array
          authorization_array_result(context, action, subject)
        else
          raise ArgumentError, 'authorization requires an ActiveRecord model, record, relation, or array of records'
        end
      end

      def validation(subject:, action:, context:)
        validate_action!(action)
        records = validation_records!(subject)
        return CheckResult.new(allowed: true, reason: :granted) if records.empty?
        records.each { |record| validate_local_lifecycle!(record, action) }

        records.each do |record|
          result = local_validation_result(context, action, record)
          return result unless result.allowed?
        end
        CheckResult.new(allowed: true, reason: :granted)
      end

      def filter(context:, action:, records:)
        raise ArgumentError, 'records cannot be nil' if records.nil?
        validate_action!(action)
        started = monotonic_time
        observe = listening?('filter')
        filter_records(context, action, records, observe: observe, started: started)
      rescue StandardError => error
        if started && observe
          emit('filter', action: action.to_s, model: nil, reason: 'error',
               timing: 'query_construction', error_class: error.class.name, duration_ms: elapsed(started))
        end
        raise
      end

      def declared_fields(context:, model:)
        roles = Configuration.roles_for(context)
        return Configuration.field_default unless roles

        model_name = model.is_a?(Class) ? Configuration.authorization_model_for(model).name : model.to_s
        role_fields_list = roles.pluck(:accessible_fields)

        return Configuration.field_default if role_fields_list.empty?

        combined = Set.new
        has_model = false

        role_fields_list.each do |af_hash|
          next unless af_hash&.key?(model_name)
          has_model = true
          fields = af_hash[model_name]
          entries = fields.is_a?(Hash) ? fields.values : [fields]
          entries.each do |value|
            return :all if value.nil? || value == :all
            combined.merge(value.map(&:to_s))
          end
        end

        return Configuration.field_default unless has_model
        combined.to_a
      end

      def potential_permissions(context: nil)
        PermissionQuery.potential_permissions(context: context)
      end

      def join_user_permissions_with_records(records, *actions, context: nil)
        PermissionQuery.join_user_permissions_with_records(records, *actions, context: context)
      end

      def primary_key!(model)
        key = model.primary_key
        unless key.is_a?(String) && !key.empty? && model.column_names.include?(key)
          raise ArgumentError, 'A single-column primary key is required; composite keys are not supported'
        end
        key
      end

      private

      def filter_records(context, action, records, observe:, started:)
        unless records.is_a?(ActiveRecord::Relation) || (records.is_a?(Class) && records < ActiveRecord::Base)
          raise ArgumentError, 'records must either be an ActiveRecord::Relation or an ActiveRecord::Base class'
        end
        if records.is_a?(ActiveRecord::Relation)
          raise ArgumentError, 'grouped relations are not supported' if records.group_values.any?

          base = ScopeEvaluator.strip_ordering_and_limits(records)
          subject = records.model
        else
          validate_model!(records)
          subject = records
          base = ScopeEvaluator.strip_ordering_and_limits(subject.all)
        end
        authorization_model = Configuration.authorization_model_for(subject)
        prepared = prepare_permissions(context, action, authorization_model, evaluated: observe)
        membership = permission_membership(context, subject, authorization_model, prepared)
        result = base.where(primary_key!(subject) => membership.reselect(subject.arel_table[primary_key!(subject)]))
        if observe
          reason = if !prepared.source
            'no_permission_source'
          elsif prepared.permissions.empty?
            'no_grants'
          elsif prepared.valid.empty?
            'no_valid_grants'
          else
            'filtered'
          end
          emit('filter', context_id: context.respond_to?(:id) ? context.id : nil,
               action: action.to_s, model: subject.name, reason: reason, timing: 'query_construction',
               permissions_count: prepared.permissions.length, valid_permissions_count: prepared.valid.length,
               conditions_evaluated: prepared.evaluated.uniq,
               scopes_applied: prepared.valid.flat_map(&:scopes).uniq,
               scope_arguments_applied: collect_arguments_applied(prepared.valid, :permission_scopes, :scope, :scopes),
               condition_arguments_applied: collect_arguments_applied(prepared.valid, :permission_conditions, :condition, :conditions),
               duration_ms: elapsed(started))
        end
        result
      end

      def grant_availability_result(context, action, model)
        authorization_model = Configuration.authorization_model_for(model)
        prepared = prepare_permissions(context, action, authorization_model, validate_scopes: false, collect_denials: true)
        return CheckResult.new(allowed: false, reason: :no_permission_source) unless prepared.source
        return CheckResult.new(allowed: false, reason: :no_grants) if prepared.permissions.empty?
        return CheckResult.new(allowed: true, reason: :granted) if prepared.valid.any?

        CheckResult.new(allowed: false, reason: denial_reason(prepared.denied), denied_grants: prepared.denied)
      end

      def authorization_array_result(context, action, records)
        return CheckResult.new(allowed: true, reason: :granted) if records.empty?
        unless records.all? { |record| record.is_a?(ActiveRecord::Base) && record.persisted? }
          raise ArgumentError, 'authorization requires persisted ActiveRecord records'
        end

        records.group_by(&:class).each_value do |group|
          model = group.first.class
          pk = primary_key!(model)
          result = saved_authorization_result(context, action, model.where(pk => group.map { |record| record.public_send(pk) }))
          return result unless result.allowed?
        end
        CheckResult.new(allowed: true, reason: :granted)
      end

      def saved_authorization_result(context, action, records)
        model = records.model
        authorization_model = Configuration.authorization_model_for(model)
        prepared = prepare_permissions(context, action, authorization_model, collect_denials: true)
        return CheckResult.new(allowed: false, reason: :no_permission_source) unless prepared.source
        return CheckResult.new(allowed: false, reason: :no_grants) if prepared.permissions.empty?
        return CheckResult.new(allowed: false, reason: denial_reason(prepared.denied), denied_grants: prepared.denied) if prepared.valid.empty?

        base = ScopeEvaluator.strip_ordering_and_limits(records)
        pk = primary_key!(model)
        permitted = permission_membership(context, model, authorization_model, prepared)
        return CheckResult.new(allowed: true, reason: :granted) unless base.where.not(pk => permitted.reselect(model.arel_table[pk])).exists?

        denials = prepared.denied + prepared.valid.map { |permission| GrantDenial.new(permission_id: permission.id, reason: :scope_mismatch) }
        CheckResult.new(allowed: false, reason: denial_reason(denials), denied_grants: denials)
      end

      def permission_membership(context, model, authorization_model, prepared, permissions: prepared.valid)
        pk = primary_key!(model)
        base = ScopeEvaluator.default_scoped_records(context, model, authorization_model)
        grant_base = ScopeEvaluator.strip_ordering_and_limits(model.all)
        # Union grants inside the default boundary so an additional grant cannot bypass that boundary.
        permissions.reduce(base.none) do |membership, permission|
          branch = ScopeEvaluator.filter_records_by_context_and_permission(
            context, model, permission, authorization_model: authorization_model,
            normalized_arguments: prepared.normalized_arguments, base: grant_base, apply_default: false
          )
          membership.or(base.where(pk => branch.reselect(model.arel_table[pk])))
        end
      end

      def validation_records!(subject)
        case subject
        when ActiveRecord::Base
          [subject]
        when Array
          unless subject.all? { |record| record.is_a?(ActiveRecord::Base) }
            raise ArgumentError, 'validation requires ActiveRecord records'
          end
          subject
        when ActiveRecord::Relation, Class
          raise ArgumentError, 'validation requires an ActiveRecord record or array of records'
        else
          raise ArgumentError, 'validation requires an ActiveRecord record or array of records'
        end
      end

      def local_validation_result(context, action, record)
        model = record.class
        authorization_model = Configuration.authorization_model_for(model)
        prepared = prepare_permissions(context, action, authorization_model, collect_denials: true)
        return CheckResult.new(allowed: false, reason: :no_permission_source) unless prepared.source
        return CheckResult.new(allowed: false, reason: :no_grants) if prepared.permissions.empty?
        permissions = prepared.valid
        return CheckResult.new(allowed: false, reason: denial_reason(prepared.denied), denied_grants: prepared.denied) if permissions.empty?

        # Saved and proposed states can be permitted by different grants.
        # Restrictions on transitions between those states belong in host validators.
        preflight_proposed_matchers!(permissions, model, authorization_model)
        return matcher_denial(prepared, permissions) unless permissions.any? { |permission|
          proposed_grant_matches?(context, record, permission, model, authorization_model,
                                  normalized_arguments: prepared.normalized_arguments)
        }

        validator_action = record.new_record? ? :create : (action.to_s == 'update' ? :update : nil)
        if validator_action && !run_action_validators(context, record, validator_action, authorization_model)
          return CheckResult.new(allowed: false, reason: :validator_rejected)
        end
        CheckResult.new(allowed: true, reason: :granted)
      end

      def validate_local_lifecycle!(record, action)
        if record.new_record?
          raise ArgumentError, 'validation requires action create for a new record' unless action.to_s == 'create'
        elsif action.to_s == 'create'
          raise ArgumentError, 'validation requires a new record for action create'
        elsif action.to_s == 'update'
          validate_update_record!(record)
        end
      end

      def matcher_denial(prepared, permissions)
        denials = prepared.denied + permissions.map do |permission|
          GrantDenial.new(permission_id: permission.id, reason: :proposed_scope_mismatch)
        end
        CheckResult.new(allowed: false, reason: :proposed_scope_mismatch, denied_grants: denials)
      end

      def validate_update_record!(record)
        model = record.class
        pk = primary_key!(model)
        if record.public_send(pk).nil? || record.will_save_change_to_attribute?(pk)
          raise ArgumentError, 'Update checks require the unchanged primary key'
        end
        if model.inheritance_column && record.will_save_change_to_attribute?(model.inheritance_column)
          raise ArgumentError, 'Update checks do not support changes to the inheritance column'
        end
        reject_pending_association_changes!(record)
      end

      def reject_pending_association_changes!(record)
        record.class.reflect_on_all_associations.each do |reflection|
          next unless record.association_cached?(reflection.name)

          target = record.association(reflection.name).target
          if Array(target).compact.any? { |child| child.new_record? || child.changed? || child.marked_for_destruction? }
            raise ArgumentError, 'Update checks support direct attributes only. Authorize pending association changes separately'
          end
        end
      end

      def prepare_permissions(context, action, authorization_model, includes: [], evaluated: false,
                              validate_scopes: true, collect_denials: false)
        PermissionPreparation.new(
          context: context,
          action: action,
          authorization_model: authorization_model,
          includes: includes,
          evaluated: evaluated,
          validate_scopes: validate_scopes,
          collect_denials: collect_denials
        ).call
      end

      def denial_reason(denied)
        %i[condition_error missing_condition condition_arguments_invalid condition_failed scope_arguments_invalid saved_scope_mismatch scope_mismatch].find do |reason|
          denied.any? { |grant| grant.reason == reason }
        end || :scope_mismatch
      end

      def validate_model!(model)
        raise ArgumentError, 'Expected an ActiveRecord model class' unless model.is_a?(Class) && model < ActiveRecord::Base
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed(started)
        ((monotonic_time - started) * 1000).round(2)
      end

      def listening?(kind)
        ActiveSupport::Notifications.notifier.listening?("permission.#{kind}.writ")
      end

      def emit(kind, payload)
        ActiveSupport::Notifications.instrument("permission.#{kind}.writ", payload)
      end

      def collect_arguments_applied(permissions, join_reader, related, key)
        id_key = :"#{related}_id"

        permissions.filter_map do |permission|
          entries = permission.public_send(join_reader).filter_map do |join_row|
            args = join_row.arguments
            next if args.nil? || args.empty?

            { id_key => join_row.public_send(id_key), name: join_row.public_send(related).name, arguments: args }
          end
          next if entries.empty?

          { permission_id: permission.id, key => entries }
        end
      end

      # Validate action format. Any lowercase alphanumeric/underscore action is allowed.
      def validate_action!(action)
        return if action.to_s.match?(Writ::NAME_FORMAT)

        sanitized = action.to_s.gsub(/[^a-zA-Z0-9_]/, '')
        raise Writ::InvalidActionError,
              "Invalid action '#{sanitized}'. Actions must be lowercase, start with a letter, " \
              "and contain only letters, numbers, and underscores"
      end

    end
  end
end
