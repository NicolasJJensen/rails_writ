# frozen_string_literal: true

module Writ
  # Mixed into the consumer's Permission model. Provides the scope/condition join
  # associations plus convenience +scopes+/+conditions+ accessors that read and write
  # through the normalized join tables (carrying per-attachment jsonb arguments).
  #
  # Read:
  #   permission.scopes              # => ["active", "in_locations"] (sorted names)
  #   permission.scope_arguments     # => { "in_locations" => { "location_ids" => [1, 2] } }
  #
  # Write (accepts names and/or { name => arguments } entries):
  #   permission.scopes = ["active", { "in_locations" => { "location_ids" => [1, 2] } }]
  #   permission.update!(conditions: ["business_hours"])
  module PermissionAssociations
    extend ActiveSupport::Concern

    included do
      has_many :permission_scopes, class_name: Configuration.model_class_name(:permission_scope), foreign_key: :permission_id, inverse_of: :permission, dependent: :destroy
      has_many :scope_records, through: :permission_scopes, source: :scope
      has_many :permission_conditions, class_name: Configuration.model_class_name(:permission_condition), foreign_key: :permission_id, inverse_of: :permission, dependent: :destroy
      has_many :condition_records, through: :permission_conditions, source: :condition

      accepts_nested_attributes_for :permission_scopes, :permission_conditions, allow_destroy: true
      validate :ap_scope_models_match

      # Apply pending scope/condition assignments inside the save transaction (fires on both
      # create and update) so the join-row writes are atomic with the rest of the save: if the
      # save rolls back, the join-row changes roll back too.
      around_save :ap_serialize_association_writes
      after_save :ap_flush_pending_associations
      after_commit :ap_clear_saved_associations
      after_rollback :ap_restore_saved_associations
    end

    def scopes
      return @ap_pending_scopes.keys.sort if @ap_pending_scopes

      permission_scopes.map { |ps| ps.scope.name }.sort
    end

    def scope_arguments
      return Writ::Configuration.canonical_arguments(@ap_pending_scopes) if @ap_pending_scopes

      permission_scopes.each_with_object({}) { |ps, acc| acc[ps.scope.name] = ps.arguments }
    end

    def scopes=(value)
      @ap_pending_scopes = ap_normalize_entries(value)
    end

    def conditions
      return @ap_pending_conditions.keys.sort if @ap_pending_conditions

      permission_conditions.map { |pc| pc.condition.name }.sort
    end

    def condition_arguments
      return Writ::Configuration.canonical_arguments(@ap_pending_conditions) if @ap_pending_conditions

      permission_conditions.each_with_object({}) { |pc, acc| acc[pc.condition.name] = pc.arguments }
    end

    def conditions=(value)
      @ap_pending_conditions = ap_normalize_entries(value)
    end

    # reload discards unsaved changes — including any pending scope/condition assignments
    # left over from a failed save — so readers reflect the database, not stale intent.
    def reload(*)
      @ap_pending_scopes = nil
      @ap_pending_conditions = nil
      @ap_saved_associations = nil
      super
    end

    private

    def ap_scope_models_match
      # The scopes setter replaces attachments against the new model during this save.
      return if @ap_pending_scopes

      permission_scopes.each do |attachment|
        next if attachment.marked_for_destruction? || attachment.scope.nil?
        if attachment.scope.model != model
          errors.add(:model, "does not match attached scope '#{attachment.scope.name}' (#{attachment.scope.model})")
        end
      end
    end

    def ap_normalize_entries(value)
      result = {}
      list = value.is_a?(Hash) ? [value] : Array(value)
      list.each do |entry|
        if entry.is_a?(Hash)
          entry.each { |k, v| result[k.to_s] = v || {} }
        else
          result[entry.to_s] = {}
        end
      end
      result
    end

    def ap_serialize_association_writes
      if persisted? && (@ap_pending_scopes || @ap_pending_conditions)
        # lock! would reload this instance and discard its pending changes.
        self.class.unscoped.where(self.class.primary_key => id_in_database).lock.pluck(self.class.primary_key)
      end
      yield
    end

    def ap_flush_pending_associations
      ap_apply_scopes(@ap_pending_scopes) if @ap_pending_scopes
      ap_apply_conditions(@ap_pending_conditions) if @ap_pending_conditions
      @ap_saved_associations ||= {}
      @ap_saved_associations[:scopes] = @ap_pending_scopes if @ap_pending_scopes
      @ap_saved_associations[:conditions] = @ap_pending_conditions if @ap_pending_conditions
      @ap_pending_scopes = nil
      @ap_pending_conditions = nil
    end

    def ap_clear_saved_associations
      @ap_saved_associations = nil
    end

    def ap_restore_saved_associations
      return unless @ap_saved_associations
      # Preserve the requested assignments after rollback so callers can
      # correct the failure and retry without assigning them again.
      @ap_pending_scopes ||= @ap_saved_associations[:scopes]
      @ap_pending_conditions ||= @ap_saved_associations[:conditions]
      @ap_saved_associations = nil
      permission_scopes.reset
      permission_conditions.reset
    end

    def ap_apply_scopes(desired)
      scope_class = Writ::Configuration.scope_class
      permission_scopes.reset
      permission_scopes.destroy_all
      desired.each do |name, args|
        scope = ap_find_or_create(scope_class, model: model, name: name.to_s)
        permission_scopes.create!(scope: scope, arguments: args || {})
      end
      permission_scopes.reset
    end

    def ap_apply_conditions(desired)
      condition_class = Writ::Configuration.condition_class
      permission_conditions.reset
      permission_conditions.destroy_all
      desired.each do |name, args|
        condition = ap_find_or_create(condition_class, name: name.to_s)
        permission_conditions.create!(condition: condition, arguments: args || {})
      end
      permission_conditions.reset
    end

    def ap_find_or_create(klass, attrs)
      RecordLookup.find_or_create!(klass, attrs)
    end
  end
end
