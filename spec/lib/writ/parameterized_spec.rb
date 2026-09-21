require 'rails_helper'
require 'writ/rake_helpers'

# End-to-end coverage for parameterized scopes and conditions:
# normalized scopes/conditions tables + permission_scopes/permission_conditions
# join rows carrying jsonb arguments.
RSpec.describe "Parameterized scopes and conditions" do
  let(:registry) { Writ::Configuration.registry }
  let(:organisation) { create(:organisation) }
  let(:user) do
    u = create(:user, organisation: organisation)
    u.roles.clear
    u
  end
  let(:role) do
    r = create(:role, organisation: organisation, name: 'Param Role')
    r.permissions.clear
    r
  end

  before { Current.user = user }
  after { Current.reset }

  # ---- Registry ----

  describe "registry argument schemas" do
    after do
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'in_locations')
      registry.remove_condition(name: 'arg_gate')
    end

    it "registers a parameterized scope and exposes its schema" do
      registry.register_scope(model_name: 'Asset', scope_name: 'in_locations',
                              arguments: { location_ids: { type: :array, required: true } }) do |_ctx, args|
        Asset.where(location_id: args[:location_ids])
      end

      expect(registry.scope_arguments_schema(model_name: 'Asset', scope_name: 'in_locations'))
        .to eq(location_ids: { type: :array, required: true })
    end

    it "registers a parameterized condition and exposes its schema" do
      registry.register_condition(name: 'arg_gate', arguments: { allow: { type: :boolean, required: true } }) do |_ctx, args|
        args[:allow]
      end

      expect(registry.condition_arguments_schema(name: 'arg_gate')).to eq(allow: { type: :boolean, required: true })
    end

    it "rejects a 1-arg callable that declares arguments (arity coupling)" do
      expect {
        registry.register_scope(model_name: 'Asset', scope_name: 'in_locations',
                                arguments: { location_ids: { type: :array } }) { |_ctx| Asset.all }
      }.to raise_error(ArgumentError, /must accept \(context, args\)/)
    end

    it "still rejects a 2-arg callable with no schema (legacy message)" do
      expect {
        registry.register_condition(name: 'arg_gate') { |_a, _b| true }
      }.to raise_error(ArgumentError, /dispatched positional arguments/)
    end
  end

  describe "#canonical_arguments" do
    it "sorts keys recursively, preserves array order, and drops empty-hash entries" do
      input = { "in_locations" => { location_ids: [3, 1, 2] }, "active" => {} }
      expect(registry.canonical_arguments(input)).to eq("in_locations" => { "location_ids" => [3, 1, 2] })
    end
  end

  describe "#validate_references! argument validation" do
    let(:test_registry) { Writ::Logic::Registry.new }

    it "fails when a permission supplies an argument of the wrong type" do
      test_registry.register_scope(model_name: 'Asset', scope_name: 'in_locations',
                                   arguments: { location_ids: { type: :array, required: true } }) { |_c, _a| Asset.all }
      test_registry.register_default_scope(model_name: 'Asset') { Asset.all }
      test_registry.register_permission(model: 'Asset', role: 'R', action: :read,
                                        scopes: [:in_locations], scope_arguments: { 'in_locations' => { 'location_ids' => 'nope' } })

      expect { test_registry.validate_references! }
        .to raise_error(Writ::ConfigurationError, /must be an array/)
    end

    it "fails when arguments are supplied for a scope with no schema" do
      test_registry.register_scope(model_name: 'Asset', scope_name: 'plain') { Asset.all }
      test_registry.register_default_scope(model_name: 'Asset') { Asset.all }
      test_registry.register_permission(model: 'Asset', role: 'R', action: :read,
                                        scopes: [:plain], scope_arguments: { 'plain' => { 'x' => 1 } })

      expect { test_registry.validate_references! }
        .to raise_error(Writ::ConfigurationError, /declares no argument schema/)
    end
  end

  # ---- DSL ----

  describe "DSL hash entries" do
    let(:test_registry) { Writ::Logic::Registry.new }
    let(:dsl) { Writ::DSL::ConfigurationDSL.new(Writ::Configuration) }

    before { allow(Writ::Configuration).to receive(:registry).and_return(test_registry) }

    it "splits { name => arguments } entries into names + arguments" do
      dsl.permission(:read, model: Asset, role: :Admin,
                     scopes: [:active, { in_locations: { location_ids: [1, 2, 3] } }],
                     conditions: [:business_hours, { arg_gate: { allow: true } }])

      perm = test_registry.all_permissions['Admin']['Asset'].first
      expect(perm[:scopes]).to eq(%w[active in_locations])
      expect(perm[:scope_arguments]).to eq("in_locations" => { "location_ids" => [1, 2, 3] })
      expect(perm[:conditions]).to eq(%w[arg_gate business_hours])
      expect(perm[:condition_arguments]).to eq("arg_gate" => { "allow" => true })
    end

    it "rejects a malformed multi-key hash entry" do
      expect {
        dsl.permission(:read, model: Asset, role: :Admin, scopes: [{ a: {}, b: {} }])
      }.to raise_error(ArgumentError, /single \{ name => arguments \} pair/)
    end

    it "rejects a non-hash argument value" do
      expect {
        dsl.permission(:read, model: Asset, role: :Admin, scopes: [{ in_locations: [1, 2] }])
      }.to raise_error(ArgumentError, /must be a Hash/)
    end
  end

  # ---- Permission model accessors + join validations ----

  describe "Permission model accessors" do
    it "reads and writes scope arguments through the join table" do
      perm = create(:permission, role: role, model: 'Asset', action: 'read',
                    scopes: [{ 'in_locations' => { 'location_ids' => [1, 2] } }, 'active'])

      expect(perm.scopes).to eq(%w[active in_locations])
      expect(perm.scope_arguments).to eq("active" => {}, "in_locations" => { "location_ids" => [1, 2] })
      expect(perm.permission_scopes.count).to eq(2)
      expect(Scope.where(model: 'Asset', name: %w[active in_locations]).count).to eq(2)
    end

    it "reads and writes condition arguments through the join table" do
      perm = create(:permission, role: role, model: 'Asset', action: 'read',
                    conditions: [{ 'arg_gate' => { 'allow' => true } }])
      expect(perm.conditions).to eq(%w[arg_gate])
      expect(perm.condition_arguments).to eq("arg_gate" => { "allow" => true })
    end
  end

  describe "join row validations" do
    after { registry.remove_scope_callable(model_name: 'Asset', scope_name: 'in_locations') }

    it "rejects arguments that violate a registered scope schema" do
      registry.register_scope(model_name: 'Asset', scope_name: 'in_locations',
                              arguments: { location_ids: { type: :array, required: true } }) { |_c, a| Asset.where(location_id: a[:location_ids]) }

      perm = create(:permission, role: role, model: 'Asset', action: 'read')
      scope = Scope.create!(model: 'Asset', name: 'in_locations')
      ps = PermissionScope.new(permission: perm, scope: scope, arguments: { 'location_ids' => 'not-an-array' })

      expect(ps).not_to be_valid
      expect(ps.errors[:arguments].join).to match(/must be an array/)
    end

    it "rejects a scope whose model does not match the permission" do
      perm = create(:permission, role: role, model: 'Asset', action: 'read')
      scope = Scope.create!(model: 'User', name: 'mismatch')
      ps = PermissionScope.new(permission: perm, scope: scope, arguments: {})

      expect(ps).not_to be_valid
      expect(ps.errors[:scope].join).to match(/does not match permission model/)
    end
  end

  # ---- Access end-to-end ----

  describe "Access with parameterized scopes" do
    let!(:loc_a) { create(:location, organisation: organisation) }
    let!(:loc_b) { create(:location, organisation: organisation) }
    let!(:loc_c) { create(:location, organisation: organisation) }
    let!(:asset_a) { create(:asset, organisation: organisation, location: loc_a) }
    let!(:asset_b) { create(:asset, organisation: organisation, location: loc_b) }
    let!(:asset_c) { create(:asset, organisation: organisation, location: loc_c) }

    before do
      registry.register_scope(model_name: 'Asset', scope_name: 'in_locations',
                              arguments: { location_ids: { type: :array, required: true } }) do |_ctx, args|
        Asset.where(location_id: args[:location_ids])
      end
      user.roles << role
    end

    after { registry.remove_scope_callable(model_name: 'Asset', scope_name: 'in_locations') }

    it "filters records using the permission's stored arguments" do
      create(:permission, role: role, model: 'Asset', action: 'read',
             scopes: [{ 'in_locations' => { 'location_ids' => [loc_a.id, loc_b.id] } }])

      result = Writ::Access.filter(context: user, action: :read, records: Asset.all)

      expect(result).to include(asset_a, asset_b)
      expect(result).not_to include(asset_c)
    end

    it "ORs two permissions that pass different arguments to the same scope" do
      role2 = create(:role, organisation: organisation, name: 'Param Role 2')
      role2.permissions.clear
      create(:permission, role: role, model: 'Asset', action: 'read',
             scopes: [{ 'in_locations' => { 'location_ids' => [loc_a.id] } }])
      create(:permission, role: role2, model: 'Asset', action: 'read',
             scopes: [{ 'in_locations' => { 'location_ids' => [loc_c.id] } }])
      user.roles << role2

      result = Writ::Access.filter(context: user, action: :read, records: Asset.all)

      expect(result).to include(asset_a, asset_c)
      expect(result).not_to include(asset_b)
    end

    it "denies all records when an array argument is empty" do
      create(:permission, role: role, model: 'Asset', action: 'read',
             scopes: [{ 'in_locations' => { 'location_ids' => [] } }])

      result = Writ::Access.filter(context: user, action: :read, records: Asset.all)
      expect(result).to be_empty
    end

    it "passes arguments as ActiveRecord predicates (injection-safe)" do
      create(:permission, role: role, model: 'Asset', action: 'read',
             scopes: [{ 'in_locations' => { 'location_ids' => ['1) OR 1=1--'] } }])

      result = Writ::Access.filter(context: user, action: :read, records: Asset.all)
      expect(result).to be_empty # the payload is treated as a value, not SQL
    end

    context "with invalid stored arguments" do
      before do
        perm = create(:permission, role: role, model: 'Asset', action: 'read',
                      scopes: [{ 'in_locations' => { 'location_ids' => [loc_a.id] } }])
        # Corrupt the stored arguments directly, bypassing model validation
        perm.permission_scopes.first.update_column(:arguments, { 'location_ids' => 'not-an-array' })
      end

      it "raises in :raise mode (default)" do
        expect {
          Writ::Access.filter(context: user, action: :read, records: Asset.all)
        }.to raise_error(Writ::InvalidArgumentsError, /must be an array/)
      end

      it "excludes only the offending permission in :deny mode" do
        original = Writ::Configuration.on_invalid_scope_arguments
        begin
          Writ::Configuration.on_invalid_scope_arguments = :deny
          allow(Writ::Configuration.logger).to receive(:error)

          result = Writ::Access.filter(context: user, action: :read, records: Asset.all)
          expect(result).to be_empty
        ensure
          Writ::Configuration.on_invalid_scope_arguments = original
        end
      end

      it "honors invalid scope argument policy when called directly" do
        original = Writ::Configuration.on_invalid_scope_arguments
        permission = role.permissions.create!(model: 'Asset', action: 'read',
                                              scopes: [{ 'in_locations' => { 'location_ids' => [loc_a.id] } }])
        permission.permission_scopes.first.update_column(:arguments, { 'location_ids' => 'not-an-array' })

        expect {
          Writ::Access::ScopeEvaluator.filter_records_by_context_and_permission(
            user, Asset, permission
          )
        }.to raise_error(Writ::InvalidArgumentsError, /must be an array/)

        Writ::Configuration.on_invalid_scope_arguments = :deny
        allow(Writ::Configuration.logger).to receive(:error)

        result = Writ::Access::ScopeEvaluator.filter_records_by_context_and_permission(
          user, Asset, permission
        )
        expect(result).to be_empty
      ensure
        Writ::Configuration.on_invalid_scope_arguments = original if original
      end
    end
  end

  describe "Access with parameterized conditions" do
    let!(:asset) { create(:asset, organisation: organisation) }

    before do
      registry.register_condition(name: 'arg_gate', arguments: { allow: { type: :boolean, required: true } }) do |_ctx, args|
        args[:allow]
      end
      user.roles << role
    end

    after { registry.remove_condition(name: 'arg_gate') }

    it "grants when the condition argument allows" do
      create(:permission, role: role, model: 'Asset', action: 'read', conditions: [{ 'arg_gate' => { 'allow' => true } }])
      expect(Writ::Access.authorization(context: user, action: :read, subject: Asset)).to be_allowed
    end

    it "denies when the condition argument disallows" do
      create(:permission, role: role, model: 'Asset', action: 'read', conditions: [{ 'arg_gate' => { 'allow' => false } }])
      expect(Writ::Access.authorization(context: user, action: :read, subject: Asset)).not_to be_allowed
    end
  end

  # ---- Generator ----

  describe "Generator with scope arguments" do
    let(:roles) { [{ name: 'Gen Param Role', description: '' }] }

    def generate(location_ids)
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation,
        roles: roles,
        permissions_by_role: {
          'Gen Param Role' => {
            permissions: [
              { action: :read, model: 'Asset', scopes: %w[in_locations], conditions: [],
                scope_arguments: { 'in_locations' => { 'location_ids' => location_ids } }, condition_arguments: {} }
            ],
            accessible_fields: []
          }
        }
      )
    end

    after do
      org_roles = organisation.roles.where(name: 'Gen Param Role')
      org_roles.each { |r| r.permissions.destroy_all }
      org_roles.destroy_all
    end

    it "persists scope arguments and is idempotent across re-runs" do
      generate([1, 2, 3])
      generate([1, 2, 3])

      perms = organisation.roles.find_by(name: 'Gen Param Role').permissions.where(action: 'read', model: 'Asset')
      expect(perms.count).to eq(1)
      expect(perms.first.scope_arguments).to eq("in_locations" => { "location_ids" => [1, 2, 3] })
    end

    it "preserves existing action arguments when migration defaults change" do
      generate([1, 2, 3])
      expect(Rails.logger).to receive(:warn).with(/Stale permission detected/)
      generate([4, 5, 6])

      perms = organisation.roles.find_by(name: 'Gen Param Role').permissions.where(action: 'read', model: 'Asset')
      expect(perms.count).to eq(1)
      expect(perms.first.scope_arguments).to eq("in_locations" => { "location_ids" => [1, 2, 3] })
    end
  end

  # ---- Stale catalog detection + cleanup ----

  describe "stale Scope/Condition catalog detection" do
    it "flags catalog rows whose scope/condition is no longer in the registry" do
      organisation # ensure the registered catalog rows exist via default generation
      stale_scope = Scope.create!(model: 'Asset', name: 'unregistered_scope_xyz')
      stale_condition = Condition.create!(name: 'unregistered_condition_xyz')

      items = Writ::Generator.stale_items(registry)

      scope_labels = items.select { |i| i[:type] == :scope }.map { |i| i[:label] }
      condition_labels = items.select { |i| i[:type] == :condition }.map { |i| i[:label] }

      expect(scope_labels).to include('Asset/unregistered_scope_xyz')
      expect(condition_labels).to include('unregistered_condition_xyz')

      # A registered scope (from the policies) is NOT flagged
      expect(scope_labels).not_to include('Asset/service_industry')
    ensure
      stale_scope&.destroy
      stale_condition&.destroy
    end

    it "flags a stale scope even while it is still referenced by a permission" do
      perm = create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['unreferenced_but_present'])
      scope = Scope.find_by!(model: 'Asset', name: 'unreferenced_but_present')

      items = Writ::Generator.stale_items(registry)
      expect(items.select { |i| i[:type] == :scope }.map { |i| i[:record] }).to include(scope)

      # The cleanup strategy (delete join rows first, then the catalog row) succeeds
      PermissionScope.where(scope_id: scope.id).delete_all
      expect { scope.delete }.to change(Scope, :count).by(-1)
      expect(perm.reload.permission_scopes).to be_empty
    end
  end

  describe Writ::RakeHelpers do
    describe ".format_named_with_args" do
      it "annotates names that carry arguments and leaves bare names alone" do
        result = described_class.format_named_with_args(
          %w[active in_locations],
          { "in_locations" => { "location_ids" => [1, 2] } }
        )
        expect(result).to eq(["active", "in_locations(location_ids: [1, 2])"])
      end
    end

    describe ".format_schema" do
      it "renders an argument schema with required markers" do
        expect(described_class.format_schema(location_ids: { type: :array, required: true }))
          .to eq(" (args: location_ids: array*)")
      end

      it "returns an empty string for no schema" do
        expect(described_class.format_schema(nil)).to eq("")
        expect(described_class.format_schema({})).to eq("")
      end
    end
  end

  # ---- Atomic join-row writes (after_save) ----

  describe "atomic scope/condition writes" do
    after { registry.remove_scope_callable(model_name: 'Asset', scope_name: 'in_locations') }

    it "rolls back join-row changes when the surrounding save fails validation" do
      registry.register_scope(model_name: 'Asset', scope_name: 'in_locations',
                              arguments: { location_ids: { type: :array, required: true } }) { |_c, a| Asset.where(location_id: a[:location_ids]) }

      perm = create(:permission, role: role, model: 'Asset', action: 'read',
                    scopes: [{ 'in_locations' => { 'location_ids' => [1] } }])

      # Invalid action (fails format validation) combined with a scope change — the whole
      # update must roll back, leaving the join rows untouched.
      expect {
        perm.update!(action: 'Bad Action!', scopes: [{ 'in_locations' => { 'location_ids' => [9, 9] } }])
      }.to raise_error(ActiveRecord::RecordInvalid)

      perm.reload
      expect(perm.action).to eq('read')
      expect(perm.scope_arguments).to eq("in_locations" => { "location_ids" => [1] })
    end

    it "applies scope changes on a plain update! (no other column change)" do
      registry.register_scope(model_name: 'Asset', scope_name: 'in_locations',
                              arguments: { location_ids: { type: :array, required: true } }) { |_c, a| Asset.where(location_id: a[:location_ids]) }

      perm = create(:permission, role: role, model: 'Asset', action: 'read',
                    scopes: [{ 'in_locations' => { 'location_ids' => [1] } }])
      perm.update!(scopes: [{ 'in_locations' => { 'location_ids' => [2, 3] } }])

      expect(perm.reload.scope_arguments).to eq("in_locations" => { "location_ids" => [2, 3] })
    end
  end

  # ---- Generator model whitelist ----

  describe "Generator model whitelist (models:)" do
    let(:roles) { [{ name: 'WL Role', description: '' }] }
    let(:both_models) do
      {
        'WL Role' => {
          permissions: [
            { action: :read, model: 'Asset', scopes: [], conditions: [] },
            { action: :read, model: 'Role', scopes: [], conditions: [] }
          ],
          accessible_fields: []
        }
      }
    end

    after do
      org_roles = organisation.roles.where(name: 'WL Role')
      org_roles.each { |r| r.permissions.destroy_all }
      org_roles.destroy_all
    end

    it "generates all models when models: is omitted (filter is optional)" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation, roles: roles, permissions_by_role: both_models
      )

      role = organisation.roles.find_by(name: 'WL Role')
      expect(role.permissions.pluck(:model).sort).to eq(%w[Asset Role])
    end

    it "generates all models when models: is explicitly nil" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation, roles: roles, permissions_by_role: both_models, models: nil
      )

      role = organisation.roles.find_by(name: 'WL Role')
      expect(role.permissions.pluck(:model).sort).to eq(%w[Asset Role])
    end

    it "only generates permissions for whitelisted models" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation, roles: roles, permissions_by_role: both_models, models: ['Asset']
      )

      role = organisation.roles.find_by(name: 'WL Role')
      expect(role.permissions.pluck(:model)).to eq(['Asset'])
    end

    it "leaves non-whitelisted models' permissions untouched and unflagged" do
      # Seed both models' permissions.
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation, roles: roles, permissions_by_role: both_models
      )
      role = organisation.roles.find_by(name: 'WL Role')
      expect(role.permissions.count).to eq(2)

      # Re-run for Asset only, with a config that omits Role entirely.
      allow(Rails.logger).to receive(:warn)
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation, roles: roles,
        permissions_by_role: {
          'WL Role' => { permissions: [{ action: :read, model: 'Asset', scopes: [], conditions: [] }], accessible_fields: [] }
        },
        models: ['Asset']
      )

      role.reload
      expect(role.permissions.pluck(:model).sort).to eq(%w[Asset Role])
      expect(Rails.logger).not_to have_received(:warn).with(/Stale permission detected/)
    end

    it "accepts model classes as well as strings" do
      Writ::Generator.generate_permissions(
        scoped_by_record: organisation, roles: roles, permissions_by_role: both_models, models: [Asset]
      )

      role = organisation.roles.find_by(name: 'WL Role')
      expect(role.permissions.pluck(:model)).to eq(['Asset'])
    end
  end

  # ---- Instrumentation: grouped (non-lossy) arguments ----

  describe "scope_arguments_applied instrumentation" do
    let!(:loc_a) { create(:location, organisation: organisation) }
    let!(:loc_b) { create(:location, organisation: organisation) }
    let!(:asset_a) { create(:asset, organisation: organisation, location: loc_a) }

    before do
      registry.register_scope(model_name: 'Asset', scope_name: 'in_locations',
                              arguments: { location_ids: { type: :array, required: true } }) do |_ctx, args|
        Asset.where(location_id: args[:location_ids])
      end
    end

    after { registry.remove_scope_callable(model_name: 'Asset', scope_name: 'in_locations') }

    def filter_event_for(action: :read)
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('permission.filter.writ') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
      begin
        Writ::Access.filter(context: user, action: action, records: Asset.all)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      events.first
    end

    it "reports raw per-permission scope arguments (no merging across permissions)" do
      role2 = create(:role, organisation: organisation, name: 'Param Role 2')
      role2.permissions.clear
      p1 = create(:permission, role: role, model: 'Asset', action: 'read',
                  scopes: [{ 'in_locations' => { 'location_ids' => [loc_a.id] } }])
      p2 = create(:permission, role: role2, model: 'Asset', action: 'read',
                  scopes: [{ 'in_locations' => { 'location_ids' => [loc_b.id] } }])
      user.roles << [role, role2]
      scope_id = Scope.find_by!(model: 'Asset', name: 'in_locations').id

      applied = filter_event_for.payload[:scope_arguments_applied]

      expect(applied).to contain_exactly(
        { permission_id: p1.id, scopes: [{ scope_id: scope_id, name: 'in_locations', arguments: { 'location_ids' => [loc_a.id] } }] },
        { permission_id: p2.id, scopes: [{ scope_id: scope_id, name: 'in_locations', arguments: { 'location_ids' => [loc_b.id] } }] }
      )
    end

    it "keeps each permission separate even when arguments are identical (raw, no dedup)" do
      role2 = create(:role, organisation: organisation, name: 'Param Role 2')
      role2.permissions.clear
      create(:permission, role: role, model: 'Asset', action: 'read',
             scopes: [{ 'in_locations' => { 'location_ids' => [loc_a.id] } }])
      create(:permission, role: role2, model: 'Asset', action: 'read',
             scopes: [{ 'in_locations' => { 'location_ids' => [loc_a.id] } }])
      user.roles << [role, role2]
      scope_id = Scope.find_by!(model: 'Asset', name: 'in_locations').id

      applied = filter_event_for.payload[:scope_arguments_applied]
      expect(applied.size).to eq(2)
      expect(applied.map { |e| e[:scopes] }).to all(eq([{ scope_id: scope_id, name: 'in_locations', arguments: { 'location_ids' => [loc_a.id] } }]))
    end

    it "omits permissions that carry no scope arguments" do
      registry.register_scope(model_name: 'Asset', scope_name: 'plain_scope') { Asset.all }
      begin
        create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['plain_scope'])
        user.roles << role

        expect(filter_event_for.payload[:scope_arguments_applied]).to eq([])
      ensure
        registry.remove_scope_callable(model_name: 'Asset', scope_name: 'plain_scope')
      end
    end
  end
end
