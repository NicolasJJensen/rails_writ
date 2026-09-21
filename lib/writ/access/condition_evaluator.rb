# frozen_string_literal: true

require_relative '../callable_helper'
require_relative '../logic/argument_validator'

# Evaluates permission conditions (boolean checks) at runtime.
# Handles condition lookup, evaluation, and error handling with
# separate paths for missing conditions vs evaluation errors.
#
# Conditions are stored as +permission_conditions+ join rows, each carrying an
# optional +arguments+ jsonb hash. Parameterized conditions declare an argument
# schema at registration and receive (context, args).
module Writ
  class Access
    class ConditionEvaluator
      class << self
        # The shared condition pipeline for boolean checks and structured results.
        # Conditions remain ANDed and stop at the first non-passing condition.
        def evaluate_with_details(permission, context, evaluated: nil)
          rows = condition_join_rows(permission)
          return { allowed: true, failed_conditions: [], reason: :granted } if rows.blank?
          registry = Writ::Configuration.registry
          rows.each do |join_row|
            name = join_row.condition.name.to_sym
            callable = registry.get_condition(name: name)
            unless callable
              if Writ::Configuration.on_missing_condition == :deny
                handle_missing_condition(name, permission)
                return denied(name, :missing_condition)
              end
              handle_missing_condition(name, permission)
            end
            args = resolve_arguments(registry, name, join_row, permission)
            if args == :invalid_denied
              return denied(name, :condition_arguments_invalid)
            end
            evaluated << name.to_s if evaluated
            completed, passed = evaluate_condition(callable, name, permission, context, args)
            return denied(name, :condition_error) unless completed
            return denied(name, :condition_failed) unless passed
          end
          { allowed: true, failed_conditions: [], reason: :granted }
        end

        # Check if all conditions for a permission are met (AND logic).
        #
        # Error handling uses three configuration options:
        #   - on_missing_condition: behavior when a condition is not registered
        #   - on_condition_error: behavior when a registered condition raises during evaluation
        #   - on_invalid_condition_arguments: behavior when stored arguments fail schema validation
        #
        # @param permission [Permission] The permission to check
        # @param context [Object] The context object
        # @return [Boolean] true if all conditions are met (or if no conditions exist)
        def conditions_met?(permission, context, evaluated: nil)
          evaluate_with_details(permission, context, evaluated: evaluated).fetch(:allowed)
        end

        private

        # Fetch the condition join rows for a permission (preloaded in the hot path).
        def condition_join_rows(permission)
          return permission.permission_conditions.to_a if permission.respond_to?(:permission_conditions)

          []
        end

        # Validate and normalize a condition's stored arguments against its schema.
        # Returns the normalized args hash, nil (no schema), or :invalid_denied.
        def resolve_arguments(registry, condition_name, join_row, permission)
          schema = registry.condition_arguments_schema(name: condition_name)
          raw = join_row.respond_to?(:arguments) ? (join_row.arguments.nil? ? {} : join_row.arguments) : {}
          return nil if schema.nil? && raw.is_a?(Hash) && raw.empty?
          errors = Writ::Logic::ArgumentValidator.errors_for(schema: schema, arguments: raw)
          return Writ::Logic::ArgumentValidator.normalize(schema: schema, arguments: raw, errors: []) if errors.empty?

          handle_invalid_arguments(condition_name, permission, errors)
        end

        def handle_invalid_arguments(condition_name, permission, errors)
          message = "[Writ] Invalid condition arguments for permission #{permission.id} " \
                    "condition '#{condition_name}': #{errors.join('; ')}"
          if Writ::Configuration.on_invalid_condition_arguments == :deny
            Writ::Configuration.logger.error(message)
            :invalid_denied
          else
            raise Writ::InvalidArgumentsError, message
          end
        end

        # Handle a condition that is not registered in the registry.
        # Uses on_missing_condition config: :raise or :deny
        def handle_missing_condition(condition_name, permission)
          error_message = "Condition '#{condition_name}' not found in registry for permission #{permission.id}. " \
                          "Register it using:\n" \
                          "  Writ.configure do\n" \
                          "    condition :#{condition_name} do |context|\n" \
                          "      # Your condition logic here\n" \
                          "    end\n" \
                          "  end"

          if Writ::Configuration.on_missing_condition == :deny
            Writ::Configuration.logger.error(error_message)
            false
          else
            raise Writ::ConditionNotFoundError, error_message
          end
        end

        # Evaluate a registered condition proc.
        # Uses on_condition_error config: :raise (default) or :deny
        def evaluate_condition(condition_proc, condition_name, permission, context, args)
          [true, Writ::CallableHelper.call_with_flexible_arity(condition_proc, context, args: args)]
        rescue => e
          if Writ::Configuration.on_condition_error == :deny
            Writ::Configuration.logger.error(
              "[Writ] Condition '#{condition_name}' raised an error during evaluation " \
              "for permission #{permission.id}: #{e.class} - #{e.message}"
            )
            [false, false]
          else
            raise
          end
        end

        def denied(name, reason)
          { allowed: false, failed_conditions: [name], reason: reason }
        end
      end
    end
  end
end
