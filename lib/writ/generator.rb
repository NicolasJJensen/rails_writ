# frozen_string_literal: true

require 'digest'
require 'json'

##
# Generates roles, permissions, and accessible fields from the DSL configuration
# registered through Writ.configure or an integration adapter.
#
module Writ
  class Generator
    class << self

      def generate_default_permissions(scoped_by_record=nil, models: nil, condition_arguments: {})
        validate_tenant_for_generation!(scoped_by_record)
        owner_roles = scoped_by_record ? scoped_by_record.roles : Writ::Configuration.role_class.all
        if owner_roles.exists?
          raise ConfigurationError, 'Default generation requires no existing roles for this owner. Use add_permissions to update existing roles'
        end
        registry = Writ::Configuration.registry
        model_filter = normalize_model_filter(models)
        permissions_by_role = build_permissions_by_role(registry, models: model_filter)
        permissions_by_role = apply_condition_arguments(permissions_by_role, condition_arguments)

        roles = permissions_by_role.keys.map do |role_name|
          { name: role_name, description: Writ::Configuration.role_description_with_fallback(role_name) }
        end

        default_role_name = Writ::Configuration.default_role_name
        roles.each { |r| r[:default] = true if r[:name] == default_role_name }

        generate_permissions(
          scoped_by_record: scoped_by_record,
          roles: roles,
          permissions_by_role: permissions_by_role,
          models: model_filter
        )
      end

      def add_permissions(scoped_by_record = nil, permissions:, condition_arguments: {})
        defaults = build_permissions_by_role(Configuration.registry)
        defaults = apply_condition_arguments(defaults, condition_arguments)
        PermissionMigration.new(scoped_by_record, permissions, defaults: defaults).apply
      end

      # Low-level migration input is explicit. Existing actions and fields remain host-owned.
      def generate_permissions(scoped_by_record: nil, roles:, permissions_by_role:, models: nil)
        validate_tenant_for_generation!(scoped_by_record)
        model_filter = normalize_model_filter(models)
        permissions_by_role = filter_permissions_by_role(permissions_by_role, model_filter) if model_filter

        Writ::Configuration.role_class.transaction do
          had_roles = scoped_by_record && scoped_by_record.roles.exists?
          roles_hash, default_role = build_roles_hash(roles, permissions_by_role)

          roles_hash.each do |role_name, role_data|
            # During a targeted (model-whitelisted) run, skip roles that have nothing to sync
            # for the whitelisted models so we don't create unrelated empty roles.
            next if model_filter &&
                    role_data[:permissions_attributes].empty? &&
                    role_data[:accessible_fields_attributes].empty?

            role = create_or_find_role(scoped_by_record, role_name, role_data)

            role.with_lock do
              sync_permissions_for_role(role, role_name, role_data, models: model_filter)
              sync_accessible_fields_for_role(role, role_name, role_data, models: model_filter)
            end
          end

          set_default_role(scoped_by_record, default_role) unless had_roles
        end
      end

      def validate_tenant_for_generation!(tenant)
        return unless Configuration.multi_tenant?
        raise ConfigurationError, 'Pass a tenant record when generating permissions in tenant mode' unless tenant
        Configuration.validate_tenant!(tenant) if Configuration.scoping_model
      end

      # Detect stale permissions and accessible fields that exist in the database
      # but are no longer present in the DSL configuration.
      #
      # @param registry [Writ::Logic::Registry]
      # @return [Array<Hash>] Array of stale item descriptors with :type, :record, :label keys
      def stale_items(registry)
        items = []
        role_class = Writ::Configuration.role_class
        permissions_by_role = build_permissions_by_role(registry)

        role_class.includes(permissions: [{ permission_scopes: :scope }, { permission_conditions: :condition }]).find_each do |role|
          role_config = permissions_by_role[role.name]

          # A role name is host-owned. If it no longer matches a configured role,
          # retain its tracked defaults; treating the rename as removal would make
          # cleanup destructive. Retire renamed roles through an explicit host migration.
          next unless role_config

          configured_sigs = configured_permission_signatures(role_config[:permissions] || [])
          retired_permissions = Set.new

          role.permissions.each do |perm|
            next unless managed_permission?(perm)
            perm_sig = permission_signature_from_record(perm)
            unless configured_sigs.include?(perm_sig)
              items << { type: :permission, record: perm, role_name: role.name,
                         label: "#{role.name}/#{perm.model}/#{perm.action}" }
              retired_permissions << perm.id
            end
          end

          expected_af_models = (role_config[:accessible_fields] || []).map { |af| af[:model] }
          current_af = role.accessible_fields || {}
          current_af.each_key do |model_name|
            next if expected_af_models.include?(model_name)
            next unless managed_field?(role, model_name)
            # Fields also constrain unchanged configured grants, not just custom grants.
            next if role.permissions.any? { |perm| perm.model == model_name && !retired_permissions.include?(perm.id) }

            items << { type: :accessible_field, role: role, role_name: role.name,
                       model_name: model_name, label: "#{role.name}/#{model_name}" }
          end
        end

        items.concat(stale_catalog_items(registry))
        items
      end

      def signature_for(permission)
        Digest::SHA256.hexdigest(JSON.generate(permission_signature_from_record(permission)))
      end

      def managed_permission?(permission)
        permission.generated_signature.present? &&
          permission.generated_signature == signature_for(permission)
      end

      def managed_field?(role, model)
        provenance = role.generated_fields || {}
        provenance.key?(model) && provenance[model] == (role.accessible_fields || {})[model]
      end

      def cleanup!(registry:, stale_items: nil, on_skip: nil)
        stale_items ||= self.stale_items(registry)
        removed_count = 0

        Writ::Configuration.role_class.transaction do
          stale_items.select { |item| item[:type] == :permission }.each do |item|
            role = item[:record].role
            role.with_lock do
              next if role.name != item[:role_name]
              next unless registry.all_permissions.key?(role.name) || registry.all_accessible_fields.key?(role.name)
              item[:record].with_lock do
                next unless managed_permission?(item[:record])
                item[:record].destroy!
                removed_count += 1
              end
            end
          end

          stale_items.select { |item| item[:type] == :accessible_field }.each do |item|
            item[:role].with_lock do
              role = item[:role]
              next if role.name != item[:role_name]
              next unless managed_field?(role, item[:model_name])
              next unless registry.all_permissions.key?(role.name) || registry.all_accessible_fields.key?(role.name)
              if role.permissions.where(model: item[:model_name]).exists?
                on_skip&.call(item, "Keeping field restriction used by a surviving grant")
                next
              end
              accessible_fields = role.accessible_fields.dup
              accessible_fields.delete(item[:model_name])
              provenance = role.generated_fields.dup
              provenance.delete(item[:model_name])
              role.update!(accessible_fields: accessible_fields, generated_fields: provenance)
              removed_count += 1
            end
          end

          stale_items.select { |item| item[:type] == :scope }.each do |item|
            if Writ::Configuration.permission_scope_class.where(scope_id: item[:record].id).exists?
              on_skip&.call(item, "Keeping referenced scope")
              next
            end

            item[:record].destroy!
            removed_count += 1
          end

          stale_items.select { |item| item[:type] == :condition }.each do |item|
            if Writ::Configuration.permission_condition_class.where(condition_id: item[:record].id).exists?
              on_skip&.call(item, "Keeping referenced condition")
              next
            end

            item[:record].destroy!
            removed_count += 1
          end
        end

        removed_count
      end

      private

      def apply_condition_arguments(permissions_by_role, overrides)
        overrides = (overrides || {}).deep_stringify_keys
        return permissions_by_role if overrides.empty?

        registry = Writ::Configuration.registry
        unknown = overrides.keys - registry.all_conditions
        if unknown.any?
          raise Writ::ConfigurationError,
                "Unknown condition argument override(s): #{unknown.join(', ')}"
        end

        permissions_by_role.deep_dup.tap do |result|
          result.each_value do |role_data|
            role_data[:permissions].each do |permission|
              names = permission[:conditions].map(&:to_s)
              names.each do |name|
                next unless overrides.key?(name)

                current = (permission[:condition_arguments] || {})[name] || {}
                override = overrides[name]
                unless current.is_a?(Hash) && override.is_a?(Hash)
                  raise ArgumentError, "Condition argument override for '#{name}' must be a hash"
                end
                permission[:condition_arguments] ||= {}
                permission[:condition_arguments][name] = current.merge(override.deep_dup)
              end
            end
          end
        end
      end

      # Membership in the registry is the sole staleness criterion (a row is stale if its
      # scope/condition is no longer defined in code), regardless of whether it is still
      # referenced by any permission.
      def stale_catalog_items(registry)
        items = []

        registered_scopes = Set.new
        registry.all_scope_callables.each do |model_name, scopes|
          scopes.each_key { |scope_name| registered_scopes << [model_name, scope_name] }
        end
        Writ::Configuration.scope_class.find_each do |scope|
          next if registered_scopes.include?([scope.model, scope.name])

          items << { type: :scope, record: scope, label: "#{scope.model}/#{scope.name}" }
        end

        registered_conditions = Set.new(registry.all_conditions)
        Writ::Configuration.condition_class.find_each do |condition|
          next if registered_conditions.include?(condition.name)

          items << { type: :condition, record: condition, label: condition.name }
        end

        items
      end

      # A permission's identity is its action, model, scopes (names + arguments), and
      # conditions (names + arguments). Any difference — including argument values — is a
      # distinct identity for provenance. Existing model/action grants are not replaced.
      def permission_signature_from_config(config)
        canon = Writ::Configuration.method(:canonical_arguments)
        [config[:action].to_s, config[:model],
         (config[:scopes] || []).map(&:to_s).sort,
         canon.call(config[:scope_arguments] || {}),
         (config[:conditions] || []).map(&:to_s).sort,
         canon.call(config[:condition_arguments] || {})]
      end

      def permission_signature_from_record(record)
        canon = Writ::Configuration.method(:canonical_arguments)
        [record.action, record.model,
         record.scopes.sort, canon.call(record.scope_arguments),
         record.conditions.sort, canon.call(record.condition_arguments)]
      end

      def entries_hash(names, arguments)
        args = (arguments || {}).transform_keys(&:to_s)
        (names || []).each_with_object({}) do |name, acc|
          acc[name.to_s] = args[name.to_s] || {}
        end
      end

      def configured_permission_signatures(permissions_config)
        Set.new(permissions_config.map { |pa| permission_signature_from_config(pa) })
      end

      def build_roles_hash(roles, permissions_by_role)
        default_role = nil

        roles_hash = roles.each_with_object({}) do |role, acc|
          default_role = role if role[:default]
          acc[role[:name]] = {
            **role.except(:default),
            permissions: [],
            accessible_fields: []
          }
        end

        permissions_by_role.each do |(role_name, role)|
          next unless roles_hash.key?(role_name)
          roles_hash[role_name][:permissions] += (role[:permissions] || [])
          roles_hash[role_name][:accessible_fields] += (role[:accessible_fields] || [])
        end

        roles_hash.each_value do |role_data|
          role_data[:permissions_attributes] = role_data.delete(:permissions)
          role_data[:accessible_fields_attributes] = role_data.delete(:accessible_fields)
        end

        [roles_hash, default_role]
      end

      def create_or_find_role(scoped_by_record, role_name, role_data)
        role = if scoped_by_record
          RecordLookup.find_or_create!(scoped_by_record.roles, name: role_name) do |r|
            r.description = role_data[:description] || ''
          end
        else
          # Single-tenant path: roles are created globally without an organisation.
          # Consumers using this path need organisation_id to be nullable on their
          # roles table (unlike multi-tenant apps where roles are scoped to an org).
          RecordLookup.find_or_create!(Writ::Configuration.role_class, name: role_name) do |r|
            r.description = role_data[:description] || ''
          end
        end


        role
      end

      # Preserve a host-customized grant for an existing model/action instead of replacing it
      # with the current defaults, which could silently change that role's access path.
      def sync_permissions_for_role(role, role_name, role_data, models: nil)
        # Build a set of existing (action, model, scope_set, scope_args) signatures for O(1) lookup
        all_existing = role.permissions.includes(permission_scopes: :scope, permission_conditions: :condition).to_a
        existing_signatures = Set.new(all_existing.map { |p| permission_signature_from_record(p) })
        existing_actions = all_existing.map { |permission| [permission.model, permission.action] }.to_set

        role_data[:permissions_attributes].each do |perm_attrs|
          next if existing_actions.include?([perm_attrs[:model], perm_attrs[:action].to_s])
          sig = permission_signature_from_config(perm_attrs)

          if existing_signatures.include?(sig)
            next
          end

          generated = role.permissions.create!(
            action: perm_attrs[:action].to_s,
            model: perm_attrs[:model],
            scopes: entries_hash(perm_attrs[:scopes], perm_attrs[:scope_arguments]),
            conditions: entries_hash(perm_attrs[:conditions], perm_attrs[:condition_arguments])
          )

          generated.update_column(:generated_signature, signature_for(generated))

          existing_signatures << sig
        end

        # When a model whitelist is in effect, only flag permissions for those models —
        # other models aren't represented in this run's config and must be left alone.
        config_sigs = configured_permission_signatures(role_data[:permissions_attributes])

        all_existing.each do |existing_perm|
          next if models && !models.include?(existing_perm.model)
          if managed_permission?(existing_perm) && !config_sigs.include?(permission_signature_from_record(existing_perm))
            Writ::Configuration.logger.warn(
              "[Writ] Stale permission detected: #{role_name}/#{existing_perm.model}/#{existing_perm.action}. " \
              "Run `rake writ:cleanup` to remove."
            )
          end
        end
      end

      def sync_accessible_fields_for_role(role, role_name, role_data, models: nil)
        new_af = {}
        role_data[:accessible_fields_attributes].each do |af_attrs|
          new_af[af_attrs[:model]] = af_attrs[:fields]
        end

        current_af = role.accessible_fields || {}

        # Flag stale entries (models no longer in config). When a model whitelist is in effect,
        # only consider those models — other models' accessible fields are out of scope this run.
        stale_models = current_af.keys - new_af.keys
        stale_models &= models if models
        stale_models.each do |model|
          next unless managed_field?(role, model)
          Writ::Configuration.logger.warn(
            "[Writ] Stale accessible_fields detected: #{role_name}/#{model}. " \
            "Run `rake writ:cleanup` to remove."
          )
        end

        provenance = (role.generated_fields || {}).dup
        merged = current_af.dup
        new_af.each do |model, fields|
          # Existing field restrictions may have been customized by the host.
          # Applying defaults again must not overwrite those choices.
          next if current_af.key?(model)
          merged[model] = fields
          provenance[model] = fields
        end
        attributes = { accessible_fields: merged }
        attributes[:generated_fields] = provenance
        role.update!(attributes)
      end

      def set_default_role(scoped_by_record, default_role)
        return unless scoped_by_record && default_role && scoped_by_record.class.method_defined?(:default_user_role=)

        scoped_by_record.default_user_role = scoped_by_record.roles.find_by(name: default_role[:name])
        scoped_by_record.save!
      end

      # :all accessible fields are converted to nil because the Generator stores nil
      # in the DB to mean "all fields accessible" (no field-level restriction).
      def build_permissions_by_role(registry, models: nil)
        all_perms = registry.all_permissions
        all_af = registry.all_accessible_fields
        result = {}

        all_perms.each do |role, models|
          result[role] = { permissions: [], accessible_fields: [] }

          models.each do |model, permissions|
            permissions.each do |perm|
              result[role][:permissions] << {
                action: perm[:action],
                model: model,
                scopes: perm[:scopes],
                conditions: perm[:conditions],
                scope_arguments: perm[:scope_arguments] || {},
                condition_arguments: perm[:condition_arguments] || {}
              }
            end

            fields = all_af.dig(role, model)
            if fields
              result[role][:accessible_fields] << {
                model: model,
                fields: fields == :all ? nil : fields
              }
            end
          end
        end

        all_af.each do |role, models|
          result[role] ||= { permissions: [], accessible_fields: [] }
          models.each do |model, fields|
            already_added = result[role][:accessible_fields].any? { |af| af[:model] == model }
            next if already_added

            result[role][:accessible_fields] << {
              model: model,
              fields: fields == :all ? nil : fields
            }
          end
        end

        if models
          result.each_value do |role_data|
            role_data[:permissions].select! { |p| models.include?(p[:model]) }
            role_data[:accessible_fields].select! { |af| models.include?(af[:model]) }
          end
          # Drop roles with nothing left for the whitelisted models so we don't create
          # unrelated roles during a targeted rollout.
          result.reject! { |_role, data| data[:permissions].empty? && data[:accessible_fields].empty? }
        end

        result
      end

      def normalize_model_filter(models)
        return nil if models.nil?

        Array(models).map { |m| m.is_a?(Class) ? m.name : m.to_s }
      end

      def filter_permissions_by_role(permissions_by_role, models)
        permissions_by_role.transform_values do |role_data|
          {
            **role_data,
            permissions: (role_data[:permissions] || []).select { |p| models.include?(p[:model]) },
            accessible_fields: (role_data[:accessible_fields] || []).select { |af| models.include?(af[:model]) }
          }
        end
      end
    end
  end
end
