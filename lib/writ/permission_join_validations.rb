# frozen_string_literal: true

module Writ
  # Shared validations for the permission_scopes / permission_conditions join models.
  # Validates that +arguments+ is a hash and (when the scope/condition is registered)
  # that the arguments satisfy the registered schema.
  module PermissionJoinValidations
    extend ActiveSupport::Concern

    private

    def arguments_is_a_hash
      errors.add(:arguments, "must be a hash") unless arguments.is_a?(Hash)
    end

    # @param registered [Boolean] whether the scope/condition is registered in the registry
    # @param schema [Hash, nil] the registered argument schema (nil when none declared)
    # @param label [String] human-readable label for error messages
    def validate_arguments_against_schema(registered:, schema:, label:)
      # Not registered (e.g. removed from code, or set up before boot): skip — runtime
      # evaluation and boot-time validate_references! are the backstops.
      return unless registered

      if schema.nil?
        errors.add(:arguments, "#{label} does not accept arguments") unless arguments.empty?
        return
      end

      Writ::Logic::ArgumentValidator.errors_for(schema: schema, arguments: arguments).each do |message|
        errors.add(:arguments, message)
      end
    end
  end
end
