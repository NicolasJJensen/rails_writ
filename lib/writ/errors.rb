# frozen_string_literal: true

module Writ
  # Base error class for all Writ errors
  class Error < StandardError; end

  # Raised when a scope callable is not registered for a given model+scope
  class MissingScopeError < Error; end

  # Raised when a scope callable returns invalid data (wrong type, wrong model)
  class InvalidScopeError < Error; end

  # Raised when scope validation fails (DB/registry mismatch)
  class ScopeValidationError < Error; end

  # Raised when an action is invalid
  class InvalidActionError < Error; end

  # Raised when a condition is not found in the registry
  class ConditionNotFoundError < Error; end

  # Raised when DSL configuration references unregistered scopes or conditions
  class ConfigurationError < Error; end

  # Raised when scope/condition arguments fail validation against their declared schema
  class InvalidArgumentsError < Error; end
end
