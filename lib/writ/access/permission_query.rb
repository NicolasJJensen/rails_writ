# frozen_string_literal: true

# UI helper methods for permission data.
# These methods are NOT access-control checks — they provide permission metadata
# for building UIs, permission matrices, and record-permission mappings.
# For actual access checks, use Access.authorization or Access.filter.
module Writ
  class Access
    class PermissionQuery
      class << self
        # Returns an ActiveRecord::Relation with virtual boolean attributes indicating
        # whether each action is permitted for each record.
        #
        # Virtual attributes are named `can_<action>` (e.g., `can_read`, `can_update`).
        # The relation is chainable — callers can apply `.where`, `.order`, `.limit`, etc.
        #
        # Uses distinct membership subqueries to avoid multiplying returned records.
        #
        # @param records [ActiveRecord::Relation] The records to check
        # @param actions [Array<Symbol>] Actions to check (e.g., :read, :update)
        # @param context [Object] Context object (typically a User)
        # @return [ActiveRecord::Relation] Records with virtual `can_<action>` boolean attributes
        def join_user_permissions_with_records(records, *actions, context: nil)
          raise ArgumentError, 'at least one action must be provided' if actions.empty?

          model = records.model
          pk = Access.primary_key!(model)
          quoted_table = model.connection.quote_table_name(model.table_name)

          query = records
          select_parts = []

          actions.map(&:to_s).uniq.each do |action|
            subquery = Access.filter(context: context, action: action, records: records)
            # RelationHandler keeps eager-loading joins without projecting their child columns.
            predicate = model.unscoped.where(pk => subquery.reselect(model.arel_table[pk])).where_clause.ast
            select_parts << predicate.as("can_#{action}")
          end

          query = query.select("#{quoted_table}.*") if records.select_values.empty?
          query.select(*select_parts)
        end

        # Returns a hash of all models and actions the context has permissions for.
        # This is a UI helper for displaying permission summaries (e.g., showing/hiding
        # navigation items, rendering permission matrices).
        #
        # NOTE: Does not evaluate conditions or scopes. Shows potential permissions,
        # not effective permissions. A user may appear to have a permission here but
        # be denied at runtime due to unmet conditions or scope restrictions.
        # For actual access checks, use Access.authorization or Access.filter.
        #
        # @param context [Object] Context object (typically a User)
        # @return [Hash] e.g., { "Asset" => { "read" => true, "create" => true } }
        def potential_permissions(context: nil)
          source = Configuration.permissions_for(context)
          return {} unless source
          source.reorder(nil).distinct.pluck(:model, :action).each_with_object({}) do |(model, action), result|
            next unless model && action
            (result[model] ||= {})[action] = true
          end
        end
      end
    end
  end
end
