class PermissionScope < ApplicationRecord
  include Writ::PermissionJoinValidations

  belongs_to :permission
  belongs_to :scope

  validates :scope_id, uniqueness: { scope: :permission_id }
  validate :arguments_is_a_hash
  validate :scope_model_matches_permission
  validate :arguments_match_schema

  private

  def scope_model_matches_permission
    return unless permission && scope
    return if scope.model == permission.model

    errors.add(:scope, "model '#{scope.model}' does not match permission model '#{permission.model}'")
  end

  # Validate arguments against the scope's registered schema (when registered).
  def arguments_match_schema
    return unless scope && arguments.is_a?(Hash)

    validate_arguments_against_schema(
      registered: Writ::Configuration.scope_callable_registered?(model_name: scope.model, scope_name: scope.name),
      schema: Writ::Configuration.scope_arguments_schema(model_name: scope.model, scope_name: scope.name),
      label: "scope '#{scope&.name}'"
    )
  rescue Writ::ConfigurationError
    # Registry/models not fully loaded (e.g. rake before boot) — skip with a warning.
    Writ::Configuration.logger.warn(
      "[Writ] Skipped scope argument validation for permission_scope (registry unavailable)"
    )
  end
end
