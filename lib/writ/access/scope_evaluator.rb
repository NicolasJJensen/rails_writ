# frozen_string_literal: true

require_relative '../callable_helper'
require_relative '../logic/argument_validator'

# Evaluates permission scopes against records.
# Handles scope application, scope merging, and callable invocation.
module Writ
  class Access
    class ScopeEvaluator
      class << self
        # Core scope-application logic for a single permission.
        # Applies default scope first (if registered), then ANDs each permission scope
        # on top. The result is a narrowed relation representing records this one
        # permission grants access to. The caller ORs results across permissions.
        # @param context [Object] Context object (typically a User, but can be anything)
        # @param subject [Class] The model class (e.g., Asset, User)
        # @param permission [Permission] The permission object containing scopes
        # @return [ActiveRecord::Relation] Filtered query
        def filter_records_by_context_and_permission(context, subject, permission, authorization_model: nil,
                                                     normalized_arguments: nil, base: nil, apply_default: true)
          authorization_model ||= Writ::Configuration.authorization_model_for(subject)
          model_name = authorization_model.name
          registry = Writ::Configuration.registry

          result = strip_ordering_and_limits(base || subject.all)

          result = default_scoped_records(context, subject, authorization_model, base: result) if apply_default

          # Apply each scope from the permission
          scope_join_rows(permission).each do |join_row|
            validate_scope_model!(join_row.scope, model_name)
            scope_name = join_row.scope.name
            callable = registry.get_scope_callable(model_name: model_name, scope_name: scope_name)

            unless callable
              raise Writ::MissingScopeError,
                    "Scope '#{scope_name}' not registered for model '#{model_name}'. " \
                    "Register it using:\n" \
                    "  Writ.configure do\n" \
                    "    scope :#{scope_name}, model: #{model_name} do |context|\n" \
                    "      #{model_name}.where(...)\n" \
                    "    end\n" \
                    "  end"
            end

            args = resolve_arguments(registry, model_name, scope_name, join_row,
                                     normalized_arguments: normalized_arguments, permission: permission)
            return result.none if args == :invalid_denied
            # Scope implementations are host code and may mutate their argument
            # hash. Pass a copy so proposed matcher evaluation sees unchanged values.
            scope_query = Writ::CallableHelper.call_with_flexible_arity(callable, context, args: args&.deep_dup)
            validate_scope_result!(scope_query, scope_name, model_name, subject, authorization_model)
            result = merge_scopes(result, scope_query)
          end

          result
        end

        def default_scoped_records(context, subject, authorization_model = nil, base: nil)
          authorization_model ||= Writ::Configuration.authorization_model_for(subject)
          result = strip_ordering_and_limits(base || subject.all)
          callable = Writ::Configuration.registry.get_default_scope(model_name: authorization_model.name)
          return result unless callable

          query = Writ::CallableHelper.call_with_flexible_arity(callable, context)
          validate_scope_result!(query, 'default_scope', authorization_model.name, subject, authorization_model)
          merge_scopes(result, query)
        end

        # Validate a permission's stored scope arguments against the registered schemas.
        # Used as a pre-filter alongside ConditionEvaluator.conditions_met?. Honors the
        # on_invalid_scope_arguments config (:raise re-raises, :deny logs + excludes).
        #
        # On success it records normalized arguments in the map owned by the current
        # authorization evaluation so the subsequent evaluation pass can reuse them without
        # mutating or retaining state on the Active Record join row.
        # @return [Boolean] true when every scope's arguments are valid
        def scope_arguments_valid?(permission, normalized_arguments: nil)
          registry = Writ::Configuration.registry

          scope_join_rows(permission).all? do |join_row|
            scope = join_row.scope
            validate_scope_model!(scope, permission.model)
            schema = registry.scope_arguments_schema(model_name: scope.model, scope_name: scope.name)
            raw = join_row.respond_to?(:arguments) ? (join_row.arguments.nil? ? {} : join_row.arguments) : {}
            next true if schema.nil? && raw.is_a?(Hash) && raw.empty?
            errors = []
            normalized = Writ::Logic::ArgumentValidator.normalize(schema: schema, arguments: raw, errors: errors)
            if errors.empty?
              normalized_arguments[join_row.object_id] = normalized if normalized_arguments
              next true
            end

            message = "[Writ] Invalid scope arguments for permission #{permission.id} " \
                      "scope '#{scope.name}': #{errors.join('; ')}"
            if Writ::Configuration.on_invalid_scope_arguments == :deny
              Writ::Configuration.logger.error(message)
              false
            else
              raise Writ::InvalidArgumentsError, message
            end
          end
        end

        # Fetch the scope join rows for a permission (preloaded in the hot path).
        def scope_join_rows(permission)
          return permission.permission_scopes.to_a if permission.respond_to?(:permission_scopes)

          []
        end

        # Return normalized arguments for a scope. The map is owned by one authorization
        # evaluation and is never stored on the Active Record attachment.
        # Returns the normalized args hash with defaults applied, or nil when no schema.
        def resolve_arguments(registry, model_name, scope_name, join_row, normalized_arguments: nil, permission: nil)
          if normalized_arguments && normalized_arguments.key?(join_row.object_id)
            return normalized_arguments[join_row.object_id]
          end

          schema = registry.scope_arguments_schema(model_name: model_name, scope_name: scope_name)
          return nil unless schema

          raw = join_row.respond_to?(:arguments) ? (join_row.arguments.nil? ? {} : join_row.arguments) : {}
          errors = []
          normalized = Writ::Logic::ArgumentValidator.normalize(schema: schema, arguments: raw, errors: errors)
          return normalized if errors.empty?

          message = "[Writ] Invalid scope arguments for permission #{permission&.id || 'unknown'} " \
                    "scope '#{scope_name}': #{errors.join('; ')}"
          if Writ::Configuration.on_invalid_scope_arguments == :deny
            Writ::Configuration.logger.error(message)
            :invalid_denied
          else
            raise Writ::InvalidArgumentsError, message
          end
        end

        # Intersect independent membership queries; merging WHERE/JOIN state can
        # overwrite predicates or change which associated rows satisfy a scope.
        def merge_scopes(base_query, scope_query)
          scope_query = strip_ordering_and_limits(scope_query)
          pk = Access.primary_key!(base_query.model)
          base_query.where(pk => scope_query.reselect(scope_query.model.arel_table[pk]))
        end

        # Strip LIMIT, ORDER, and OFFSET from a relation that should only contribute
        # WHERE and JOIN clauses to a permission query.
        #
        # Permission scopes and input relations should not carry ordering or pagination
        # into the permission-checking layer. Callers should apply ordering/pagination
        # after Access.filter builds the membership relation, not before.
        #
        # @param relation [ActiveRecord::Relation] The relation to strip
        # @return [ActiveRecord::Relation] Stripped relation
        def strip_ordering_and_limits(relation)
          has_order = relation.order_values.any?
          has_limit = relation.limit_value.present?
          has_offset = relation.offset_value.present?

          if has_order || has_limit || has_offset
            parts = []
            parts << 'ORDER' if has_order
            parts << 'LIMIT' if has_limit
            parts << 'OFFSET' if has_offset
            Writ::Configuration.logger.warn(
              "[Writ] Stripping #{parts.join(', ')} from relation on #{relation.model.name} " \
              "during permission evaluation. Apply ordering/pagination after permission filtering."
            )
          end

          result = relation
          result = result.reorder(nil) if has_order
          result = result.limit(nil) if has_limit
          result = result.offset(nil) if has_offset
          result
        end

        private

        def validate_scope_model!(scope, model_name)
          return if scope.model == model_name

          raise Writ::ScopeValidationError,
                "Scope '#{scope.name}' belongs to model '#{scope.model}', not permission model '#{model_name}'"
        end

        def validate_scope_result!(query, scope_name, model_name, subject, authorization_model = subject)
          unless query.is_a?(ActiveRecord::Relation)
            raise Writ::InvalidScopeError,
                  "Scope '#{scope_name}' for '#{model_name}' must return an ActiveRecord::Relation, got #{query.class}"
          end
          unless query.model == subject || query.model == authorization_model
            raise Writ::InvalidScopeError,
                  "Scope '#{scope_name}' for '#{model_name}' must return a #{model_name} relation, got #{query.model.name}"
          end
          if query.group_values.any?
            raise Writ::InvalidScopeError,
                  "Scope '#{scope_name}' for '#{model_name}' must not return a grouped relation"
          end
        end
      end
    end
  end
end
