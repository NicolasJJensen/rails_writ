require 'rails_helper'

RSpec.describe Writ::Generator do
  let(:organisation) { create(:organisation) }

  describe ".build_permissions_by_role" do
    let(:registry) { Writ::Logic::Registry.new }

    it "returns permissions structured for Generator" do
      registry.register_permission(model: "Asset", role: "Technician", action: :read, scopes: [:service_industry])
      registry.register_permission(model: "Asset", role: "Technician", action: :create, scopes: [])

      result = described_class.send(:build_permissions_by_role, registry)

      expect(result).to have_key("Technician")
      expect(result["Technician"][:permissions].count).to eq(2)

      read_perm = result["Technician"][:permissions].find { |p| p[:action] == :read }
      expect(read_perm[:model]).to eq("Asset")
      expect(read_perm[:scopes]).to eq(["service_industry"])
    end

    it "returns scope names as strings, not AR objects" do
      registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [:service_industry])

      result = described_class.send(:build_permissions_by_role, registry)
      scopes = result["Admin"][:permissions].first[:scopes]

      scopes.each do |scope_val|
        expect(scope_val).to be_a(String)
      end
    end

    it "includes accessible fields" do
      registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [])
      registry.register_accessible_fields(model: "Asset", role: "Admin", fields: [:name, :status])

      result = described_class.send(:build_permissions_by_role, registry)
      af = result["Admin"][:accessible_fields].first

      expect(af[:model]).to eq("Asset")
      expect(af[:fields]).to eq(%w[create read update delete].to_h { |action| [action, %w[name status]] })
    end

    it "preserves unrestricted CRUD field entries for generation" do
      registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [])
      registry.register_accessible_fields(model: "Asset", role: "Admin", fields: :all)

      result = described_class.send(:build_permissions_by_role, registry)
      af = result["Admin"][:accessible_fields].first

      expect(af[:fields]).to eq(%w[create read update delete].to_h { |action| [action, nil] })
    end

    it "includes roles that only have accessible fields (no permissions)" do
      registry.register_accessible_fields(model: "Asset", role: "Viewer", fields: [:name])

      result = described_class.send(:build_permissions_by_role, registry)

      expect(result).to have_key("Viewer")
      expect(result["Viewer"][:permissions]).to eq([])
      expect(result["Viewer"][:accessible_fields].count).to eq(1)
      expect(result["Viewer"][:accessible_fields].first[:model]).to eq("Asset")
      expect(result["Viewer"][:accessible_fields].first[:fields]).to eq(%w[create read update delete].to_h { |action| [action, ["name"]] })
    end
  end

  describe ".generate_permissions" do
    let(:roles) do
      [
        { name: "Gen Test Role", description: "Test role for generator" }
      ]
    end

    let(:permissions_by_role) do
      {
        "Gen Test Role" => {
          permissions: [
            { action: :read, model: "Asset", scopes: %w[gen_test_scope_a], conditions: [] },
            { action: :create, model: "Asset", scopes: [], conditions: [] }
          ],
          accessible_fields: [
            { model: "Asset", fields: %i[name status] }
          ]
        }
      }
    end

    after do
      # Clean up generated data
      org_roles = organisation.roles.where(name: "Gen Test Role")
      org_roles.each do |role|
        role.permissions.destroy_all
      end
      org_roles.destroy_all
    end

    it "creates roles on the scoped record" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: permissions_by_role
      )

      role = organisation.roles.find_by(name: "Gen Test Role")
      expect(role).to be_present
    end

    it "rejects a required condition template without tenant arguments atomically" do
      registry = Writ::Configuration.registry
      registry.register_condition(
        name: 'tenant_ids_for_generation',
        arguments: { ids: { type: :array, required: true } }
      ) { |_context, _args| true }

      expect do
        described_class.generate_permissions(
          scoped_by_record: organisation,
          roles: roles,
          permissions_by_role: {
            'Gen Test Role' => {
              permissions: [{ action: :read, model: 'Role', scopes: [], conditions: ['tenant_ids_for_generation'] }],
              accessible_fields: []
            }
          }
        )
      end.to raise_error(ActiveRecord::RecordInvalid, /required argument 'ids'/i)

      expect(organisation.roles.find_by(name: 'Gen Test Role')).to be_nil
    ensure
      registry.remove_condition(name: 'tenant_ids_for_generation') if registry
    end

    it "accepts tenant-specific condition arguments for independent generations" do
      registry = Writ::Configuration.registry
      registry.register_condition(
        name: 'tenant_ids_for_generation',
        arguments: { ids: { type: :array, required: true } }
      ) { |_context, _args| true }
      permission_config = lambda do |ids|
        {
          'Gen Test Role' => {
            permissions: [{ action: :read, model: 'Role', scopes: [],
                            conditions: ['tenant_ids_for_generation'],
                            condition_arguments: { 'tenant_ids_for_generation' => { ids: ids } } }],
            accessible_fields: []
          }
        }
      end

      second_organisation = create(:organisation)
      described_class.generate_permissions(scoped_by_record: organisation, roles: roles,
                                           permissions_by_role: permission_config.call([organisation.id]))
      described_class.generate_permissions(scoped_by_record: second_organisation, roles: roles,
                                           permissions_by_role: permission_config.call([second_organisation.id]))

      expect(organisation.roles.find_by(name: 'Gen Test Role').permissions.first.condition_arguments)
        .to eq('tenant_ids_for_generation' => { 'ids' => [organisation.id] })
      expect(second_organisation.roles.find_by(name: 'Gen Test Role').permissions.first.condition_arguments)
        .to eq('tenant_ids_for_generation' => { 'ids' => [second_organisation.id] })
    ensure
      registry.remove_condition(name: 'tenant_ids_for_generation') if registry
    end

    it "creates permissions with correct actions" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: permissions_by_role
      )

      role = organisation.roles.find_by(name: "Gen Test Role")
      expect(role.permissions.count).to eq(2)
      expect(role.permissions.pluck(:action).sort).to eq(%w[create read])
    end

    it "associates scopes with permissions" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: permissions_by_role
      )

      role = organisation.roles.find_by(name: "Gen Test Role")
      read_perm = role.permissions.find_by(action: "read", model: "Asset")
      expect(read_perm.scopes).to include("gen_test_scope_a")
    end

    it "creates accessible fields" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: permissions_by_role
      )

      role = organisation.roles.find_by(name: "Gen Test Role")
      expect(role.accessible_fields).to have_key("Asset")
      expect(role.accessible_fields["Asset"]).to eq(%w[name status])
    end

    it "is idempotent — calling twice creates no duplicates" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: permissions_by_role
      )

      role_count = organisation.roles.where(name: "Gen Test Role").count
      perm_count = organisation.roles.find_by(name: "Gen Test Role").permissions.count

      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: permissions_by_role
      )

      expect(organisation.roles.where(name: "Gen Test Role").count).to eq(role_count)
      expect(organisation.roles.find_by(name: "Gen Test Role").permissions.count).to eq(perm_count)
    end

    context "with multiple permissions for same action+model but different scopes" do
      let(:permissions_by_role) do
        {
          "Gen Test Role" => {
            permissions: [
              { action: :read, model: "Asset", scopes: %w[gen_test_scope_a], conditions: [] },
              { action: :read, model: "Asset", scopes: %w[gen_test_scope_b], conditions: [] }
            ],
            accessible_fields: []
          }
        }
      end

      it "creates separate permission records for each scope set" do
        Writ::Generator.generate_permissions(
          scoped_by_record: organisation,
          roles: roles,
          permissions_by_role: permissions_by_role
        )

        role = organisation.roles.find_by(name: "Gen Test Role")
        read_perms = role.permissions.where(action: "read", model: "Asset")
        expect(read_perms.count).to eq(2)
      end

      it "associates different scopes with each permission record" do
        Writ::Generator.generate_permissions(
          scoped_by_record: organisation,
          roles: roles,
          permissions_by_role: permissions_by_role
        )

        role = organisation.roles.find_by(name: "Gen Test Role")
        read_perms = role.permissions.where(action: "read", model: "Asset")
        scope_sets = read_perms.map { |p| p.scopes.sort }

        expect(scope_sets).to contain_exactly(%w[gen_test_scope_a], %w[gen_test_scope_b])
      end

      it "is idempotent with multiple same-action permissions" do
        2.times do
          Writ::Generator.generate_permissions(
            scoped_by_record: organisation,
            roles: roles,
            permissions_by_role: permissions_by_role
          )
        end

        role = organisation.roles.find_by(name: "Gen Test Role")
        read_perms = role.permissions.where(action: "read", model: "Asset")
        expect(read_perms.count).to eq(2)
      end
    end

    it "preserves existing fields when migration defaults change" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: permissions_by_role
      )

      # Change the fields and re-generate
      updated_by_role = permissions_by_role.deep_dup
      updated_by_role["Gen Test Role"][:accessible_fields] = [
        { model: "Asset", fields: %i[name status location] }
      ]

      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: updated_by_role
      )

      role = organisation.roles.find_by(name: "Gen Test Role")
      expect(role.accessible_fields["Asset"]).to eq(%w[name status])
    end
  end

  describe ".associate_conditions_with_permissions" do
    let(:roles) do
      [{ name: "Cond Test Role", description: "" }]
    end

    let(:permissions_by_role) do
      {
        "Cond Test Role" => {
          permissions: [
            { action: :read, model: "Asset", scopes: [], conditions: %w[test_condition_a test_condition_b] }
          ],
          accessible_fields: []
        }
      }
    end

    after do
      org_roles = organisation.roles.where(name: "Cond Test Role")
      org_roles.each do |role|
        role.permissions.destroy_all
      end
      org_roles.destroy_all
    end

    it "creates conditions and associates them with permissions" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: permissions_by_role
      )

      role = organisation.roles.find_by(name: "Cond Test Role")
      read_perm = role.permissions.find_by(action: "read", model: "Asset")
      condition_names = read_perm.conditions.sort

      expect(condition_names).to eq(%w[test_condition_a test_condition_b])
    end

    it "does not duplicate conditions on re-generation" do
      2.times do
        Writ::Generator.generate_permissions(
          scoped_by_record: organisation,
          roles: roles,
          permissions_by_role: permissions_by_role
        )
      end

      role = organisation.roles.find_by(name: "Cond Test Role")
      read_perm = role.permissions.find_by(action: "read", model: "Asset")
      expect(read_perm.conditions.length).to eq(2)
    end

    context "with multiple same-action permissions and different conditions per scope set" do
      let(:permissions_by_role) do
        {
          "Cond Test Role" => {
            permissions: [
              { action: :read, model: "Asset", scopes: %w[cond_scope_a], conditions: %w[test_condition_a] },
              { action: :read, model: "Asset", scopes: %w[cond_scope_b], conditions: %w[test_condition_b] }
            ],
            accessible_fields: []
          }
        }
      end

      it "attaches conditions to the correct permission based on scope set" do
        Writ::Generator.generate_permissions(
          scoped_by_record: organisation,
          roles: roles,
          permissions_by_role: permissions_by_role
        )

        role = organisation.roles.find_by(name: "Cond Test Role")
        read_perms = role.permissions.where(action: "read", model: "Asset")

        perm_with_scope_a = read_perms.find { |p| p.scopes == %w[cond_scope_a] }
        perm_with_scope_b = read_perms.find { |p| p.scopes == %w[cond_scope_b] }

        expect(perm_with_scope_a.conditions).to eq(%w[test_condition_a])
        expect(perm_with_scope_b.conditions).to eq(%w[test_condition_b])
      end
    end
  end

  describe ".generate_permissions global (scoped_by_record: nil)" do
    it "invokes the global code path without scoped_by_record" do
      original_tenancy = Writ::Configuration.multi_tenant
      Writ::Configuration.multi_tenant = false
      # In single-tenant apps where Role doesn't require an organisation,
      # generate_permissions(scoped_by_record: nil) creates roles directly via role_class.
      # This test app's Role requires organisation, so verify the code path is called correctly.
      roles = [{ name: "Global Test Role", description: "Global role" }]
      permissions_by_role = {
        "Global Test Role" => {
          permissions: [{ action: :read, model: "Role", scopes: [], conditions: [] }],
          accessible_fields: []
        }
      }

      # The global path calls role_class.find_or_create_by! (not scoped_by_record.roles)
      expect(Writ::Configuration.role_class).to receive(:find_or_create_by!).with({ name: "Global Test Role" }).and_call_original

      # Will raise because this app's Role requires organisation — that's expected
      expect {
        Writ::Generator.generate_permissions(
          roles: roles,
          permissions_by_role: permissions_by_role
        )
      }.to raise_error(ActiveRecord::RecordInvalid, /Organisation/)
    ensure
      Writ::Configuration.multi_tenant = original_tenancy
    end
  end

  describe ".generate_default_permissions" do
    it "builds roles from registry and generates permissions" do
      # The organisation factory calls generate_default_permissions via after_create
      org = create(:organisation)

      expect(org.roles.count).to be > 0

      # Should have the roles defined in AssetPolicy (Admin, Technician, etc.)
      role_names = org.roles.pluck(:name)
      expect(role_names).to include("Admin")
    end

    it "accepts tenant condition arguments without mutating the registry template" do
      first = create(:organisation)
      second = create(:organisation)
      first.roles.destroy_all
      second.roles.destroy_all
      original_registry = Writ::Configuration.registry
      registry = Writ::Logic::Registry.new
      Writ::Configuration.instance_variable_set(:@registry, registry)
      registry.register_condition(
        name: 'tenant_default_gate', arguments: {
          ids: { type: :array, required: true }, mode: { type: :string }
        }
      ) { |_context, _args| true }
      registry.register_permission(model: 'Role', role: 'TenantAdmin', action: :read,
                                   scopes: [], conditions: ['tenant_default_gate'],
                                   condition_arguments: { tenant_default_gate: { mode: 'strict' } })
      described_class.generate_default_permissions(first, condition_arguments: { tenant_default_gate: { ids: [first.id] } })
      described_class.generate_default_permissions(second, condition_arguments: { tenant_default_gate: { ids: [second.id] } })

      expect(first.roles.find_by(name: 'TenantAdmin').permissions.first.condition_arguments)
        .to eq('tenant_default_gate' => { 'ids' => [first.id], 'mode' => 'strict' })
      expect(second.roles.find_by(name: 'TenantAdmin').permissions.first.condition_arguments)
        .to eq('tenant_default_gate' => { 'ids' => [second.id], 'mode' => 'strict' })
      expect(registry.all_permissions.dig('TenantAdmin', 'Role').first[:condition_arguments])
        .to eq('tenant_default_gate' => { 'mode' => 'strict' })
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry)
    end

    it "rejects a missing required tenant condition argument before creating default roles" do
      organisation = create(:organisation)
      organisation.roles.destroy_all
      original_registry = Writ::Configuration.registry
      registry = Writ::Logic::Registry.new
      Writ::Configuration.instance_variable_set(:@registry, registry)
      registry.register_condition(
        name: 'tenant_default_gate', arguments: { ids: { type: :array, required: true } }
      ) { |_context, _args| true }
      registry.register_permission(model: 'Role', role: 'TenantAdmin', action: :read,
                                   scopes: [], conditions: ['tenant_default_gate'])
      expect {
        described_class.generate_default_permissions(organisation)
      }.to raise_error(ActiveRecord::RecordInvalid, /required argument 'ids'/i)
      expect(organisation.roles.reload).to be_empty
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry)
    end

    it "rejects unknown tenant condition overrides before generation" do
      organisation = create(:organisation)
      organisation.roles.destroy_all
      original_registry = Writ::Configuration.registry
      registry = Writ::Logic::Registry.new
      Writ::Configuration.instance_variable_set(:@registry, registry)
      registry.register_condition(name: 'tenant_default_gate') { true }
      registry.register_permission(model: 'Role', role: 'TenantAdmin', action: :read,
                                   scopes: [], conditions: ['tenant_default_gate'])

      expect {
        described_class.generate_default_permissions(organisation, condition_arguments: { not_registered: { ids: [1] } })
      }.to raise_error(Writ::ConfigurationError, /Unknown condition argument override/)
      expect(organisation.roles.reload).to be_empty
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry)
    end

    it "allows overrides for registered conditions that are unused by selected grants" do
      organisation = create(:organisation)
      organisation.roles.destroy_all
      original_registry = Writ::Configuration.registry
      registry = Writ::Logic::Registry.new
      Writ::Configuration.instance_variable_set(:@registry, registry)
      registry.register_condition(name: 'unused_gate', arguments: { ids: { type: :array } }) { |_ctx, _args| true }

      expect {
        described_class.generate_default_permissions(organisation, condition_arguments: { unused_gate: { ids: [1] } })
      }.not_to raise_error
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry)
    end

    it "rejects a tenant override with the wrong schema type atomically" do
      organisation = create(:organisation)
      organisation.roles.destroy_all
      original_registry = Writ::Configuration.registry
      registry = Writ::Logic::Registry.new
      Writ::Configuration.instance_variable_set(:@registry, registry)
      registry.register_condition(name: 'tenant_default_gate', arguments: { ids: { type: :array, required: true } }) { |_ctx, _args| true }
      registry.register_permission(model: 'Role', role: 'TenantAdmin', action: :read,
                                   scopes: [], conditions: ['tenant_default_gate'])

      expect {
        described_class.generate_default_permissions(organisation, condition_arguments: { tenant_default_gate: { ids: 'wrong' } })
      }.to raise_error(ActiveRecord::RecordInvalid, /must be an array/i)
      expect(organisation.roles.reload).to be_empty
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry)
    end
  end

  describe "stale permission detection logs warning (TEST-11)" do
    let(:roles) { [{ name: "Stale Detect Role", description: "" }] }

    after do
      org_roles = organisation.roles.where(name: "Stale Detect Role")
      org_roles.each do |role|
        role.permissions.destroy_all
      end
      org_roles.destroy_all
    end

    it "logs a warning for permissions no longer in config" do
      # First generate with a permission
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: {
          "Stale Detect Role" => {
            permissions: [
              { action: :read, model: "Role", scopes: [], conditions: [] },
              { action: :create, model: "Role", scopes: [], conditions: [] }
            ],
            accessible_fields: []
          }
        }
      )

      # Re-generate with one permission removed
      expect(Rails.logger).to receive(:warn).with(/Stale permission detected.*Stale Detect Role\/Role\/create/)

      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: {
          "Stale Detect Role" => {
            permissions: [
              { action: :read, model: "Role", scopes: [], conditions: [] }
            ],
            accessible_fields: []
          }
        }
      )
    end
  end

  describe ".stale_items" do
    it "returns an array of stale item descriptors" do
      registry = Writ::Configuration.registry
      result = Writ::Generator.stale_items(registry)
      expect(result).to be_a(Array)
    end

    it "preserves untracked permissions not in registry config" do
      registry = Writ::Configuration.registry

      # Create a role with a permission that doesn't match registry config
      role = organisation.roles.find_by(name: 'Admin') || create(:role, organisation: organisation, name: 'Admin')
      stale_perm = role.permissions.create!(action: 'delete', model: 'NonexistentModel')

      begin
        result = Writ::Generator.stale_items(registry)
        stale_perms = result.select { |item| item[:type] == :permission }

        expect(stale_perms.map { |s| s[:label] }).not_to include("Admin/NonexistentModel/delete")
      ensure
        stale_perm.destroy
      end
    end

    it "preserves untracked accessible fields not in registry config" do
      registry = Writ::Configuration.registry

      role = organisation.roles.find_by(name: 'Admin') || create(:role, organisation: organisation, name: 'Admin')
      original_af = role.accessible_fields.dup
      role.update!(accessible_fields: role.accessible_fields.merge("NonexistentModel" => ["id"]))

      begin
        result = Writ::Generator.stale_items(registry)
        stale_afs = result.select { |item| item[:type] == :accessible_field }

        expect(stale_afs.map { |s| s[:label] }).not_to include("Admin/NonexistentModel")
      ensure
        role.update!(accessible_fields: original_af)
      end
    end

  end

  describe "scope set ordering normalization (TEST-R26-7)" do
    let(:roles) { [{ name: "Order Test Role", description: "" }] }

    after do
      org_roles = organisation.roles.where(name: "Order Test Role")
      org_roles.each do |role|
        role.permissions.destroy_all
      end
      org_roles.destroy_all
    end

    it "treats differently-ordered scope arrays as the same permission" do

      # First generation with scopes [beta, alpha]
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: {
          "Order Test Role" => {
            permissions: [
              { action: :read, model: "Asset", scopes: %w[scope_beta scope_alpha], conditions: [] }
            ],
            accessible_fields: []
          }
        }
      )

      role = organisation.roles.find_by(name: "Order Test Role")
      expect(role.permissions.count).to eq(1)

      # Second generation with scopes [alpha, beta] — should not create duplicate
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: {
          "Order Test Role" => {
            permissions: [
              { action: :read, model: "Asset", scopes: %w[scope_alpha scope_beta], conditions: [] }
            ],
            accessible_fields: []
          }
        }
      )

      role.reload
      expect(role.permissions.count).to eq(1)
    end
  end

  describe "condition names are part of permission identity (TEST-R26-14)" do
    let(:roles) { [{ name: "Cond Stale Role", description: "" }] }

    after do
      org_roles = organisation.roles.where(name: "Cond Stale Role")
      org_roles.each do |role|
        role.permissions.destroy_all
      end
      org_roles.destroy_all
    end

    it "preserves the existing action when default conditions change" do
      # Generate with a condition
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: {
          "Cond Stale Role" => {
            permissions: [
              { action: :read, model: "Role", scopes: [], conditions: %w[removed_condition] }
            ],
            accessible_fields: []
          }
        }
      )

      role = organisation.roles.find_by(name: "Cond Stale Role")
      original = role.permissions.find_by(action: "read", model: "Role")
      expect(original.conditions).to eq(['removed_condition'])

      expect(Rails.logger).to receive(:warn).with(/Stale permission detected/)
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: {
          "Cond Stale Role" => {
            permissions: [
              { action: :read, model: "Role", scopes: [], conditions: [] }
            ],
            accessible_fields: []
          }
        }
      )

      read_perms = role.permissions.where(action: "read", model: "Role")
      expect(read_perms.map { |p| p.conditions }).to contain_exactly(['removed_condition'])
    end
  end

  describe "role description update on re-generation (TEST-R26-15)" do
    let(:roles_v1) { [{ name: "Desc Update Role", description: "First" }] }
    let(:roles_v2) { [{ name: "Desc Update Role", description: "Updated" }] }
    let(:permissions_by_role) do
      {
        "Desc Update Role" => {
          permissions: [{ action: :read, model: "Role", scopes: [], conditions: [] }],
          accessible_fields: []
        }
      }
    end

    after do
      org_roles = organisation.roles.where(name: "Desc Update Role")
      org_roles.each do |role|
        role.permissions.destroy_all
      end
      org_roles.destroy_all
    end

    it "preserves the role description when migration defaults change" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles_v1,
        permissions_by_role: permissions_by_role
      )

      role = organisation.roles.find_by(name: "Desc Update Role")
      expect(role.description).to eq("First")

      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles_v2,
        permissions_by_role: permissions_by_role
      )

      role.reload
      expect(role.description).to eq("First")
    end
  end

  describe "full lifecycle integration" do
    # DSL → generate permissions → verify DB records
    it "creates correct DB records from registry configuration" do
      # Build a fresh registry with known configuration
      test_registry = Writ::Logic::Registry.new
      test_registry.register_scope(model_name: 'Asset', scope_name: 'lifecycle_scope') { |ctx| Asset.all }
      test_registry.register_permission(model: 'Asset', role: 'Lifecycle Role', action: :read, scopes: [:lifecycle_scope])
      test_registry.register_role_description(role: 'Lifecycle Role', description: 'Integration test role')

      # Temporarily swap the global registry
      original_registry = Writ::Configuration.instance_variable_get(:@registry)
      Writ::Configuration.instance_variable_set(:@registry, test_registry)

      begin
        # Generate permissions
        Writ::Generator.generate_permissions(
          scoped_by_record: organisation,
          roles: [{ name: 'Lifecycle Role', description: 'Integration test role' }],
          permissions_by_role: Writ::Generator.send(:build_permissions_by_role, test_registry)
        )

        role = organisation.roles.find_by(name: 'Lifecycle Role')
        expect(role).to be_present
        expect(role.description).to eq('Integration test role')
        expect(role.permissions.count).to eq(1)

        perm = role.permissions.first
        expect(perm.action).to eq('read')
        expect(perm.model).to eq('Asset')
        expect(perm.scopes).to eq(%w[lifecycle_scope])
      ensure
        # Cleanup
        Writ::Configuration.instance_variable_set(:@registry, original_registry)
        org_role = organisation.roles.find_by(name: 'Lifecycle Role')
        if org_role
          org_role.permissions.destroy_all
          org_role.destroy
        end
      end
    end
  end
end
