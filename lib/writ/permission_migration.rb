# frozen_string_literal: true

module Writ
  class PermissionMigration
    def initialize(tenant, permissions, defaults:)
      @tenant = tenant
      @selection = normalize(permissions)
      @defaults = defaults
      known = @defaults.values.flat_map { |data| data[:permissions].map { |grant| [grant[:model], grant[:action].to_s] } }
      unknown = @selection - known
      raise ArgumentError, "No configured permissions match #{unknown.inspect}" unless unknown.empty?
    end

    def apply
      Generator.validate_tenant_for_generation!(@tenant)
      Configuration.role_class.transaction do
        @defaults.each do |name, data|
          grants = data[:permissions].select { |grant| @selection.include?([grant[:model], grant[:action].to_s]) }
          next if grants.empty?
          roles = @tenant ? @tenant.roles : Configuration.role_class.all
          role = RecordLookup.find_or_create!(roles, name: name) do |record|
            record.description = Configuration.role_description_with_fallback(name)
          end
          role.with_lock { add_missing(role, grants, data[:accessible_fields]) }
        end
      end
    end

    private

    def normalize(permissions)
      unless permissions.is_a?(Array) && permissions.any?
        raise ArgumentError, 'Select at least one permission by model and action'
      end
      permissions.map do |entry|
        unless entry.is_a?(Hash) && entry.keys.sort == [:action, :model]
          raise ArgumentError, 'Each selection must contain model: and action:'
        end
        model = entry[:model].is_a?(Class) ? entry[:model].name : entry[:model].to_s
        action = entry[:action].to_s
        unless model.present? && action.match?(Writ::NAME_FORMAT)
          raise ArgumentError, 'Each selection needs a model name and a valid action'
        end
        [model, action]
      end.uniq
    end

    def add_missing(role, grants, field_defaults)
      grants.group_by { |grant| [grant[:model], grant[:action].to_s] }.each do |(model, action), alternatives|
        next if role.permissions.where(model: model, action: action).exists?
        alternatives.each do |grant|
          permission = role.permissions.create!(
            model: model, action: action,
            scopes: entries(grant[:scopes], grant[:scope_arguments]),
            conditions: entries(grant[:conditions], grant[:condition_arguments])
          )
          permission.update_column(:generated_signature, Generator.signature_for(permission))
        end
        add_missing_fields(role, model, action, field_defaults)
      end
    end

    def entries(names, arguments)
      names.to_h { |name| [name, (arguments || {}).fetch(name, {})] }
    end

    def add_missing_fields(role, model, action, defaults)
      definition = defaults.find { |entry| entry[:model] == model }
      return unless definition
      fields = (role.accessible_fields || {}).deep_dup
      value = definition[:fields]
      if fields.key?(model)
        return unless fields[model].is_a?(Hash) && value.is_a?(Hash)
        return if fields[model].key?(action) || !value.key?(action)
        fields[model][action] = value[action]
      else
        fields[model] = value.is_a?(Hash) ? value.slice(action) : value
      end
      # Migration fields are host-owned. Whole-model provenance cannot track one added action safely.
      role.update!(accessible_fields: fields)
    end

  end
end
