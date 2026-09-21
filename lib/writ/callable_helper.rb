# frozen_string_literal: true

# Shared callable invocation logic used by both ScopeEvaluator and ConditionEvaluator.
# Extracted to avoid a cross-layer dependency where ConditionEvaluator reached into
# ScopeEvaluator for a method that isn't scope-specific.
module Writ
  module CallableHelper
    module_function

    # Call a callable with flexible arity.
    #
    # Supports several invocation modes; this library is designed to be
    # extracted as a gem, so all modes are supported for consumer flexibility:
    #   - 0-param callables use Current attributes for context (e.g., Current.user)
    #   - 1-param callables receive the context object directly
    #   - 2-param callables (arity 2, -2, -3) receive (context, args) for parameterized
    #     scopes/conditions that declare an `arguments:` schema
    #
    # @param callable [Proc] The block-backed callable
    # @param context [Object] The context to pass (if callable accepts it)
    # @param args [Object, nil] The normalized argument hash (for parameterized callables)
    # @return [Object] The callable result
    def call_with_flexible_arity(callable, context, args: nil)
      arity = callable.arity
      if !args.nil?
        callable.call(context, args)
      elsif arity.zero?
        callable.call
      else
        callable.call(context)
      end
    end
  end
end
