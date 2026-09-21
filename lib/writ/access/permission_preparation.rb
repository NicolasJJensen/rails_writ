# frozen_string_literal: true

module Writ
  class Access
    # Builds the permission set shared by record, relation, validation, and
    # field decisions. Keeping condition and stored-argument handling here
    # ensures those public APIs make the same grant eligibility decision while
    # retaining their distinct membership and proposed-state checks.
    class PermissionPreparation
      def initialize(context:, action:, authorization_model:, includes: [], evaluated: false,
                     validate_scopes: true, collect_denials: false)
        @context = context
        @action = action
        @authorization_model = authorization_model
        @includes = includes
        @evaluated = evaluated
        @validate_scopes = validate_scopes
        @collect_denials = collect_denials
      end

      def call
        source = Configuration.permissions_for(@context)
        normalized_arguments = {}
        permissions = load_permissions(source)
        visited = @evaluated ? [] : nil
        denied = []
        valid = permissions.each_with_object([]) do |permission, accepted|
          condition = ConditionEvaluator.evaluate_with_details(permission, @context, evaluated: visited)
          unless condition[:allowed]
            add_condition_denial(denied, permission, condition) if @collect_denials
            next
          end

          if @validate_scopes && !ScopeEvaluator.scope_arguments_valid?(
            permission, normalized_arguments: normalized_arguments
          )
            add_scope_denial(denied, permission) if @collect_denials
            next
          end

          accepted << permission
        end

        Access::PreparedPermissions.new(
          source: source,
          permissions: permissions,
          valid: valid,
          denied: denied,
          evaluated: visited,
          normalized_arguments: normalized_arguments
        )
      end

      private

      def load_permissions(source)
        return [] unless source

        relation = source.where(model: @authorization_model.name, action: @action)
        relation = relation.includes(@includes) unless @includes.blank?
        relation.includes(permission_scopes: :scope, permission_conditions: :condition).to_a
      end

      def add_condition_denial(denied, permission, condition)
        denied << GrantDenial.new(
          permission_id: permission.id,
          reason: condition[:reason],
          failed_conditions: condition[:failed_conditions]
        )
      end

      def add_scope_denial(denied, permission)
        denied << GrantDenial.new(permission_id: permission.id, reason: :scope_arguments_invalid)
      end
    end
  end
end
