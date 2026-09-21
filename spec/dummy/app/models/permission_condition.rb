class PermissionCondition < ApplicationRecord
  include Writ::PermissionJoinValidations

  belongs_to :permission
  belongs_to :condition

  validates :condition_id, uniqueness: { scope: :permission_id }
  validate :arguments_is_a_hash
  validate :arguments_match_schema

  private

  # Validate arguments against the condition's registered schema (when registered).
  def arguments_match_schema
    return unless condition && arguments.is_a?(Hash)

    validate_arguments_against_schema(
      registered: Writ::Configuration.condition_registered?(name: condition.name),
      schema: Writ::Configuration.condition_arguments_schema(name: condition.name),
      label: "condition '#{condition&.name}'"
    )
  rescue Writ::ConfigurationError
    Writ::Configuration.logger.warn(
      "[Writ] Skipped condition argument validation for permission_condition (registry unavailable)"
    )
  end
end
