require 'rails_helper'
require 'ostruct'

# Eager load Policy classes for Access tests (registers scopes in registry)
Dir[Rails.root.join('app/policies/**/*.rb')].each { |f| require f }

# Load Current class for context attributes
require Rails.root.join('app/models/current_attributes/current.rb')

RSpec.describe Writ::Access do
  include ActiveSupport::Testing::TimeHelpers

  def register_default_scope_from(registry, model_name, callable, **options)
    return unless callable

    registry.register_default_scope(model_name: model_name, **options) do |context|
      callable.call(context)
    end
  end

  describe ".potential_permissions" do
    it "returns hash of permissions by model and action" do
      organisation = create(:organisation)
      user = create(:user, organisation: organisation)
      admin_role = organisation.roles.where(name: 'Admin').first
      user.roles << admin_role if admin_role

      result = Writ::Access.potential_permissions(context: user)

      expect(result).to be_a(Hash)
      # Admin role should have Asset permissions (read, create, update, delete) from AssetPolicy
      expect(result).to have_key('Asset')
      expect(result['Asset']).to include('read' => true, 'create' => true, 'update' => true, 'delete' => true)
    end

    it "returns empty hash when user has no roles" do
      organisation = create(:organisation)
      user_without_roles = create(:user, organisation: organisation)
      user_without_roles.roles.clear

      result = Writ::Access.potential_permissions(context: user_without_roles)

      expect(result).to be_a(Hash)
      # User with no roles should have no meaningful permissions
      expect(result.keys).to be_empty
    end

    it "handles nil context gracefully" do
      result = Writ::Access.potential_permissions(context: nil)
      expect(result).to eq({})
    end
  end

  describe ".authorization" do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }
    let(:role) { create(:role, organisation: organisation) }

    before { Current.user = user }
    after { Current.reset }

    it "returns false for nil context" do
      result = Writ::Access.authorization(context: nil, action: :read, subject: Role)
      expect(result).not_to be_allowed
    end

    it "raises error for nil records" do
      expect {
        Writ::Access.authorization(context: user, action: :read, subject: nil)
      }.to raise_error(ArgumentError, /authorization requires/)
    end

    it "raises error for invalid records type" do
      expect {
        Writ::Access.authorization(context: user, action: :read, subject: "invalid")
      }.to raise_error(ArgumentError, /authorization requires/)
    end

    it "checks permission for model class" do
      # Give user permission to read roles
      permission = create(:permission, role: role, model: 'Role', action: 'read')
      user.roles << role

      result = Writ::Access.authorization(context: user, action: :read, subject: Role)

      expect(result).to be_allowed
    end

    it "returns false when user has no permission for model class" do
      # Create user with no roles
      user_without_roles = create(:user, organisation: organisation)
      user_without_roles.roles.clear

      result = Writ::Access.authorization(context: user_without_roles, action: :read, subject: Role)

      expect(result).not_to be_allowed
    end

    it "checks permission for relation" do
      # Create some roles and give user permission to read them
      role1 = create(:role, organisation: organisation, name: 'Test Role 1')
      role2 = create(:role, organisation: organisation, name: 'Test Role 2')
      permission = create(:permission, role: role, model: 'Role', action: 'read')
      user.roles << role

      # Test with a relation containing all roles the user has access to
      accessible_roles = Role.where(id: [role1.id, role2.id], organisation: organisation)
      result = Writ::Access.authorization(context: user, action: :read, subject: accessible_roles)

      expect(result).to be_allowed

      # Test with a relation containing a role from a different organisation
      other_organisation = create(:organisation, name: 'Other Org')
      other_role = create(:role, organisation: other_organisation, name: 'Other Role')
      mixed_roles = Role.where(id: [role1.id, other_role.id])

      result = Writ::Access.authorization(context: user, action: :read, subject: mixed_roles)
      # Should be false because user doesn't have permission for the role in the other organisation
      expect(result).not_to be_allowed
    end

    it "checks permission for single record" do
      # Create a role and give user permission to read it
      test_role = create(:role, organisation: organisation, name: 'Test Role')
      permission = create(:permission, role: role, model: 'Role', action: 'read')
      user.roles << role

      # Test with a single record the user has access to
      result = Writ::Access.authorization(context: user, action: :read, subject: test_role)

      expect(result).to be_allowed

      # Test with a record from a different organisation
      other_organisation = create(:organisation, name: 'Other Org')
      other_role = create(:role, organisation: other_organisation, name: 'Other Role')

      result = Writ::Access.authorization(context: user, action: :read, subject: other_role)
      # Should be false because user doesn't have permission for roles in other organisations
      expect(result).not_to be_allowed
    end

    it "authorizes a new record for create from its class grant" do
      create(:permission, role: role, model: 'Asset', action: 'create')
      user.roles << role

      expect(Writ::Access.authorization(context: user, action: :create, subject: Asset.new)).to be_allowed
    end

    it "checks create-grant conditions for a new record without local validation" do
      original_registry = Writ::Configuration.registry
      Writ::Configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
      Writ::Configuration.register_condition(name: 'new_record_gate') { false }
      create(:permission, role: role, model: 'Asset', action: 'create', conditions: ['new_record_gate'])
      user.roles << role
      validator_calls = 0
      Writ::Configuration.register_creation_validator(model_name: 'Asset') do |context:, record:|
        validator_calls += 1
        false
      end

      result = Writ::Access.authorization(context: user, action: :create, subject: Asset.new)

      expect(result).not_to be_allowed
      expect(validator_calls).to eq(0)
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry) if original_registry
    end

    it "rejects unsaved records for actions other than create" do
      expect {
        Writ::Access.authorization(context: user, action: :read, subject: Asset.new)
      }.to raise_error(ArgumentError, /persisted record/)
    end
  end

  describe ".filter" do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }
    let(:role) { create(:role, organisation: organisation) }

    before { Current.user = user }
    after { Current.reset }

    it "returns empty relation for nil context" do
      # nil context is allowed - just returns empty
      result = Writ::Access.filter(context: nil, action: :read, records: Role)
      expect(result).to be_a(ActiveRecord::Relation)
      expect(result.count).to eq(0)
    end

    it "raises error for nil records" do
      expect {
        Writ::Access.filter(context: user, action: :read, records: nil)
      }.to raise_error(ArgumentError, 'records cannot be nil')
    end

    it "raises error for invalid records type" do
      expect {
        Writ::Access.filter(context: user, action: :read, records: "invalid")
      }.to raise_error(ArgumentError, /records must/)
    end

    it "returns empty relation when user has no permissions" do
      # Create user with no roles
      user_without_roles = create(:user, organisation: organisation)
      user_without_roles.roles.clear

      result = Writ::Access.filter(context: user_without_roles, action: :read, records: Role)

      expect(result).to be_a(ActiveRecord::Relation)
      expect(result.count).to eq(0)
    end

    it "filters records based on permissions" do
      # Give user permission to read roles
      permission = create(:permission, role: role, model: 'Role', action: 'read')
      user.roles << role

      result = Writ::Access.filter(context: user, action: :read, records: Role.all)

      expect(result).to be_a(ActiveRecord::Relation)
      # Should return roles in user's organisation
      expect(result.where(organisation: organisation).count).to be >= 1
    end
  end

  describe ".join_user_permissions_with_records" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation, name: 'Join Test Role')
      r.permissions.clear
      r
    end

    before { Current.user = user }
    after { Current.reset }

    it "returns an ActiveRecord::Relation with virtual boolean attributes" do
      # Give user read but not delete permission
      create(:permission, role: role, model: 'Role', action: 'read')
      user.roles << role

      roles = organisation.roles
      result = Writ::Access.join_user_permissions_with_records(
        roles, :read, :delete, context: user
      )

      expect(result).to be_a(ActiveRecord::Relation)

      # Virtual attributes accessible on each record
      permitted_role = result.find { |r| r.id == role.id }
      expect(permitted_role).to be_present
      expect(permitted_role.can_read).to be true
      expect(permitted_role.can_delete).to be false
    end

    it "is chainable with .where, .order, .limit" do
      create(:permission, role: role, model: 'Role', action: 'read')
      user.roles << role

      roles = organisation.roles
      result = Writ::Access.join_user_permissions_with_records(
        roles, :read, context: user
      )

      # Chain .where — use .to_a.size because .count generates SELECT COUNT(*)
      # which conflicts with the virtual CASE WHEN columns
      filtered = result.where(id: role.id)
      expect(filtered.to_a.size).to eq(1)
      expect(filtered.first.can_read).to be true

      # Chain .order and .limit
      ordered = result.order(:name).limit(1)
      expect(ordered.to_a.length).to be <= 1
    end

    it "handles empty permissions (no roles assigned)" do
      roles = organisation.roles
      result = Writ::Access.join_user_permissions_with_records(
        roles, :read, :update, context: user
      )

      expect(result).to be_a(ActiveRecord::Relation)
      result.each do |record|
        expect(record.can_read).to be false
        expect(record.can_update).to be false
      end
    end
  end

  describe "InvalidActionError" do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }

    it "accepts custom actions in authorization" do
      expect {
        Writ::Access.authorization(context: user, action: :view, subject: Role)
      }.not_to raise_error
    end

    it "accepts custom actions in filter" do
      expect {
        Writ::Access.filter(context: user, action: :view, records: Role)
      }.not_to raise_error
    end

    it "rejects malformed actions in authorization" do
      expect {
        Writ::Access.authorization(context: user, action: :"bad action!", subject: Role)
      }.to raise_error(Writ::InvalidActionError)
    end

    it "rejects malformed actions in filter" do
      expect {
        Writ::Access.filter(context: user, action: :"bad action!", records: Role)
      }.to raise_error(Writ::InvalidActionError)
    end
  end

  describe ".potential_permissions ignoring conditions" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation, name: 'Condition Ignore Role')
      r.permissions.clear
      r
    end

    it "returns permissions regardless of condition state" do
      # Create a permission with a condition that would fail at runtime
      permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['always_fails_for_all_perms'])

      registry = Writ::Configuration.registry
      registry.register_condition(name: 'always_fails_for_all_perms') { |_| false }

      user.roles << role

      begin
        result = Writ::Access.potential_permissions(context: user)

        # potential_permissions does NOT evaluate conditions — it shows potential permissions
        expect(result).to have_key('Role')
        expect(result['Role']).to include('read' => true)
      ensure
        registry.remove_condition(name: 'always_fails_for_all_perms')
      end
    end
  end

  describe "non-standard context object" do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }

    before { Current.user = user }
    after { Current.reset }

    it "works with OpenStruct context that responds to permissions" do
      role = create(:role, organisation: organisation, name: 'OpenStruct Role')
      role.permissions.clear
      create(:permission, role: role, model: 'Role', action: 'read')

      # OpenStruct context with a permissions association mimic
      context = OpenStruct.new(
        id: user.id,
        organisation_id: organisation.id,
        permissions: role.permissions
      )

      result = Writ::Access.authorization(context: context, action: :read, subject: Role)
      expect(result).to be_allowed
    end
  end

  describe "condition-based permissions" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear # Remove all default roles
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation, name: 'Conditional Role')
      r.permissions.clear # Remove any default permissions
      r
    end
    let(:secondary_role) do
      r = create(:role, organisation: organisation, name: 'Secondary Role')
      r.permissions.clear # Remove any default permissions
      r
    end

    before do
      # Register test conditions in the registry
      registry = Writ::Configuration.registry

      # Generic true/false conditions for various tests
      %w[single_true multi_true_1 multi_true_2 multi_any_true where_true mixed_permission_true].each do |name|
        registry.register_condition(name: name) { |context| true }
      end

      %w[single_false multi_any_false multi_all_false_1 multi_all_false_2 where_false mixed_permission_false].each do |name|
        registry.register_condition(name: name) { |context| false }
      end

      # Time-based conditions with unique names
      %w[time_weekday time_early time_weekend where_time].each do |name|
        registry.register_condition(name: name) do |context|
          hour = Time.current.hour
          weekday = [1, 2, 3, 4, 5].include?(Time.current.wday) # Monday-Friday
          (9..17).cover?(hour) && weekday
        end
      end

      # IP-based conditions with unique names
      %w[test_office_ip_grant test_office_ip_deny where_ip].each do |name|
        registry.register_condition(name: name) do |context|
          Current.ip_address&.start_with?('192.168')
        end
      end

      # Device-based conditions with unique names
      %w[test_desktop_grant test_desktop_deny].each do |name|
        registry.register_condition(name: name) do |context|
          Current.device_type == :desktop
        end
      end

      Current.user = user
    end

    after do
      # Clean up all test conditions using the public API
      registry = Writ::Configuration.registry

      # Remove all test condition names
      test_names = %w[single_true multi_true_1 multi_true_2 multi_any_true where_true mixed_permission_true
                      single_false multi_any_false multi_all_false_1 multi_all_false_2 where_false mixed_permission_false
                      time_weekday time_early time_weekend where_time
                      test_office_ip_grant test_office_ip_deny where_ip
                      test_desktop_grant test_desktop_deny]

      test_names.each { |name| registry.remove_condition(name: name) }
      Current.reset
    end

    describe "permissions without conditions" do
      it "grants access when permission has no conditions" do
        permission = create(:permission, role: role, model: 'Role', action: 'read')
        user.roles << role

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        expect(result).to be_allowed
      end
    end

    describe "permissions with single condition" do
      it "grants access when condition passes" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['single_true'])
        user.roles << role

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        expect(result).to be_allowed
      end

      it "denies access when condition fails" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['single_false'])
        user.roles << role

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        expect(result).not_to be_allowed
      end

      it "raises error when condition is not registered (in test/dev)" do
        unregistered_name = "unregistered_#{SecureRandom.hex(4)}"
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: [unregistered_name])
        user.roles << role

        expect {
          Writ::Access.authorization(context: user, action: :read, subject: Role)
        }.to raise_error(Writ::ConditionNotFoundError)
      end
    end

    describe "permissions with multiple conditions (AND logic)" do
      it "grants access when all conditions pass" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['multi_true_1', 'multi_true_2'])
        user.roles << role

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        expect(result).to be_allowed
      end

      it "denies access when any condition fails" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['multi_any_true', 'multi_any_false'])
        user.roles << role

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        expect(result).not_to be_allowed
      end

      it "denies access when all conditions fail" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['multi_all_false_1', 'multi_all_false_2'])
        user.roles << role

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        expect(result).not_to be_allowed
      end
    end

    describe "time-based conditions" do
      it "grants access during business hours on weekday" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['time_weekday'])
        user.roles << role

        # Mock time to Tuesday at 2pm
        travel_to Time.zone.local(2024, 1, 16, 14, 0, 0) do
          result = Writ::Access.authorization(context: user, action: :read, subject: Role)
          expect(result).to be_allowed
        end
      end

      it "denies access outside business hours" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['time_early'])
        user.roles << role

        # Mock time to Tuesday at 8am (before business hours)
        travel_to Time.zone.local(2024, 1, 16, 8, 0, 0) do
          result = Writ::Access.authorization(context: user, action: :read, subject: Role)
          expect(result).not_to be_allowed
        end
      end

      it "denies access on weekends" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['time_weekend'])
        user.roles << role

        # Mock time to Saturday at 2pm
        travel_to Time.zone.local(2024, 1, 20, 14, 0, 0) do
          result = Writ::Access.authorization(context: user, action: :read, subject: Role)
          expect(result).not_to be_allowed
        end
      end
    end

    describe "context-based conditions" do
      it "grants access from office IP" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['test_office_ip_grant'])
        user.roles << role

        # Mock Current attributes with office IP
        Current.ip_address = '192.168.1.100'

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        expect(result).to be_allowed

        # Clean up
        Current.ip_address = nil
      end

      it "denies access from non-office IP" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['test_office_ip_deny'])
        user.roles << role

        # Mock Current attributes with external IP
        Current.ip_address = '203.0.113.1'

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        expect(result).not_to be_allowed

        # Clean up
        Current.ip_address = nil
      end

      it "grants access from desktop device" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['test_desktop_grant'])
        user.roles << role

        # Mock Current attributes with desktop device
        Current.device_type = :desktop

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        expect(result).to be_allowed

        # Clean up
        Current.device_type = nil
      end

      it "denies access from mobile device" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['test_desktop_deny'])
        user.roles << role

        # Mock Current attributes with mobile device
        Current.device_type = :mobile

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        expect(result).not_to be_allowed

        # Clean up
        Current.device_type = nil
      end
    end

    describe "filter with conditions" do
      it "returns empty relation when conditions fail" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['where_false'])
        user.roles << role

        result = Writ::Access.filter(context: user, action: :read, records: Role.all)

        expect(result).to be_a(ActiveRecord::Relation)
        expect(result.count).to eq(0)
      end

      it "returns filtered records when conditions pass" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['where_true'])
        user.roles << role

        result = Writ::Access.filter(context: user, action: :read, records: Role.all)

        expect(result).to be_a(ActiveRecord::Relation)
        expect(result.where(organisation: organisation).count).to be >= 1
      end

      it "filters based on time and context conditions" do
        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['where_time', 'where_ip'])
        user.roles << role

        # Mock time and IP to satisfy both conditions
        Current.ip_address = '192.168.1.100'
        travel_to Time.zone.local(2024, 1, 16, 14, 0, 0) do
          result = Writ::Access.filter(context: user, action: :read, records: Role.all)

          expect(result).to be_a(ActiveRecord::Relation)
          expect(result.where(organisation: organisation).count).to be >= 1
        end

        # Clean up
        Current.ip_address = nil
      end
    end

    describe "mixed permissions (with and without conditions)" do
      it "grants access when user has at least one valid permission" do
        # Permission with failing condition
        permission1 = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['mixed_permission_false'])
        user.roles << role

        # Permission without conditions on another role
        permission2 = create(:permission, role: secondary_role, model: 'Role', action: 'read')
        user.roles << secondary_role

        result = Writ::Access.authorization(context: user, action: :read, subject: Role)

        # Should grant access via permission2
        expect(result).to be_allowed
      end
    end
  end

  describe "input edge cases" do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }

    it "handles missing scope callable registration" do
      # Create a permission with a scope that doesn't exist in the registry
      test_role = create(:role, organisation: organisation)
      nonexistent_scope_name = "test_nonexistent_#{SecureRandom.hex(4)}"
      permission = create(:permission, role: test_role, model: 'Asset', action: 'read', scopes: [nonexistent_scope_name])
      user.roles << test_role

      # Trying to filter with a non-registered scope should raise an error
      expect {
        Writ::Access.filter(context: user, action: :read, records: Asset.all)
      }.to raise_error(Writ::MissingScopeError, /Scope .* not registered for model 'Asset'/)
    end

    it "handles relation with .group() applied by raising a clear error" do
      # .group() is guarded in authorization to avoid silent misbehavior
      grouped = Role.where(organisation: organisation).group(:name)
      expect {
        Writ::Access.authorization(
          context: user, action: :read, subject: grouped
        )
      }.to raise_error(ArgumentError, /group/)
    end

    it "rejects grouped relations in filter" do
      grouped = Role.where(organisation: organisation).group(:name)
      expect {
        Writ::Access.filter(
          context: user, action: :read, records: grouped
        )
      }.to raise_error(ArgumentError, /group/)
    end
  end

  describe "edge cases" do
    let(:organisation) { create(:organisation) }
    let(:service_industry) { create(:service_industry) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u.service_industries << service_industry
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation, name: 'Edge Case Role')
      r.permissions.clear
      r
    end
    let(:permission) { create(:permission, role: role, action: 'read', model: 'Asset') }
    let(:asset) do
      a = create(:asset, organisation: organisation)
      a.service_industries << service_industry
      a
    end

    before do
      user.roles << role
      Current.user = user
    end

    after { Current.reset }

    describe "empty conditions array" do
      it "grants access when permission has empty conditions array" do
        permission.update!(scopes: ['service_industry'], conditions: [])
        user.reload

        result = Writ::Access.authorization(context: user, action: :read, subject: asset)

        expect(result).to be_allowed
      end
    end

    describe "nil context values" do
      it "handles nil ip_address gracefully" do
        permission.update!(conditions: ['requires_ip'], scopes: ['service_industry'])

        registry = Writ::Configuration.registry
        registry.register_condition(name: 'requires_ip') do |context|
          Current.ip_address&.start_with?('192.168') || false
        end

        begin
          Current.ip_address = nil

          result = Writ::Access.authorization(context: user, action: :read, subject: asset)

          expect(result).not_to be_allowed
        ensure
          registry.remove_condition(name: 'requires_ip')
          Current.reset
        end
      end

      it "handles nil user_agent gracefully" do
        permission.update!(conditions: ['requires_user_agent'], scopes: ['service_industry'])

        registry = Writ::Configuration.registry
        registry.register_condition(name: 'requires_user_agent') do |context|
          Current.user_agent&.include?('Chrome') || false
        end

        begin
          Current.user_agent = nil

          result = Writ::Access.authorization(context: user, action: :read, subject: asset)

          expect(result).not_to be_allowed
        ensure
          registry.remove_condition(name: 'requires_user_agent')
          Current.reset
        end
      end

      it "handles all nil context values" do
        permission.update!(conditions: ['checks_all_context'], scopes: ['service_industry'])

        registry = Writ::Configuration.registry
        registry.register_condition(name: 'checks_all_context') do |context|
          ip = Current.ip_address
          agent = Current.user_agent
          request = Current.request_id
          device = Current.device_type

          # Return true if any value exists
          [ip, agent, request, device].any?(&:present?)
        end

        begin
          # All Current attributes are nil by default
          Current.reset

          result = Writ::Access.authorization(context: user, action: :read, subject: asset)

          expect(result).not_to be_allowed
        ensure
          registry.remove_condition(name: 'checks_all_context')
        end
      end
    end

    describe "missing condition in registry" do
      it "raises ConditionNotFoundError in test environment when condition not registered" do
        permission.update!(conditions: ['unregistered_condition'], scopes: ['service_industry'])

        expect {
          Writ::Access.authorization(context: user, action: :read, subject: asset)
        }.to raise_error(Writ::ConditionNotFoundError, /unregistered_condition/)
      end

      it "error message includes registration instructions" do
        permission.update!(conditions: ['missing_condition'], scopes: ['service_industry'])

        expect {
          Writ::Access.authorization(context: user, action: :read, subject: asset)
        }.to raise_error(Writ::ConditionNotFoundError, /condition :missing_condition/)
      end
    end

    describe "on_missing_condition = :deny mode" do
      it "catches condition errors and logs them in :deny mode" do
        original_missing_mode = Writ::Configuration.on_missing_condition
        original_error_mode = Writ::Configuration.on_condition_error

        begin
          Writ::Configuration.on_missing_condition = :deny
          Writ::Configuration.on_condition_error = :deny

          permission.update!(conditions: ['deny_mode_error_raiser'], scopes: ['service_industry'])

          registry = Writ::Configuration.registry
          registry.register_condition(name: 'deny_mode_error_raiser') do |context|
            raise StandardError, "Unexpected error in condition"
          end

          expect(Rails.logger).to receive(:error).with(/Condition 'deny_mode_error_raiser' raised/)

          result = Writ::Access.authorization(context: user, action: :read, subject: asset)
          expect(result).not_to be_allowed
        ensure
          Writ::Configuration.on_missing_condition = original_missing_mode
          Writ::Configuration.on_condition_error = original_error_mode
          registry.remove_condition(name: 'deny_mode_error_raiser')
        end
      end

      it "silently denies when condition is unregistered and mode is :deny" do
        original_mode = Writ::Configuration.on_missing_condition

        begin
          Writ::Configuration.on_missing_condition = :deny

          permission.update!(conditions: ['deny_mode_unregistered'], scopes: ['service_industry'])

          result = Writ::Access.authorization(context: user, action: :read, subject: asset)

          expect(result).not_to be_allowed
        ensure
          Writ::Configuration.on_missing_condition = original_mode
        end
      end
    end

    describe "condition edge behaviors" do
      it "handles condition that returns truthy non-boolean value" do
        permission.update!(conditions: ['returns_truthy'], scopes: ['service_industry'])

        registry = Writ::Configuration.registry
        registry.register_condition(name: 'returns_truthy') do |context|
          "truthy string"  # Returns non-boolean truthy value
        end

        begin
          result = Writ::Access.authorization(context: user, action: :read, subject: asset)

          # Ruby treats non-nil, non-false as truthy
          expect(result).to be_allowed
        ensure
          registry.remove_condition(name: 'returns_truthy')
        end
      end

      it "handles condition that returns falsy value (nil)" do
        permission.update!(conditions: ['returns_nil'], scopes: ['service_industry'])

        registry = Writ::Configuration.registry
        registry.register_condition(name: 'returns_nil') do |context|
          nil
        end

        begin
          result = Writ::Access.authorization(context: user, action: :read, subject: asset)

          expect(result).not_to be_allowed
        ensure
          registry.remove_condition(name: 'returns_nil')
        end
      end

      it "raises error when condition raises an error" do
        permission.update!(conditions: ['raises_error'], scopes: ['service_industry'])

        registry = Writ::Configuration.registry
        registry.register_condition(name: 'raises_error') do |context|
          raise StandardError, "Condition error"
        end

        begin
          expect {
            Writ::Access.authorization(context: user, action: :read, subject: asset)
          }.to raise_error(StandardError, /Condition error/)
        ensure
          registry.remove_condition(name: 'raises_error')
        end
      end
    end

    describe "multiple conditions with partial registry coverage" do
      it "fails if any condition is missing from registry (all must be registered)" do
        permission.update!(conditions: ['registered_edge', 'unregistered_edge'], scopes: ['service_industry'])

        registry = Writ::Configuration.registry
        # Only register one condition
        registry.register_condition(name: 'registered_edge') { |context| true }

        begin
          expect {
            Writ::Access.authorization(context: user, action: :read, subject: asset)
          }.to raise_error(Writ::ConditionNotFoundError, /unregistered_edge/)
        ensure
          registry.remove_condition(name: 'registered_edge')
        end
      end
    end

    describe "permission with no scopes" do
      it "handles permission with only conditions (no scopes)" do
        permission.update!(conditions: ['only_condition'])
        # Don't add any scopes to permission

        registry = Writ::Configuration.registry
        registry.register_condition(name: 'only_condition') { |context| true }

        begin
          result = Writ::Access.authorization(context: user, action: :read, subject: asset)

          # Should grant access even with no scopes if condition passes
          expect(result).to be_allowed
        ensure
          registry.remove_condition(name: 'only_condition')
        end
      end
    end

    describe "empty permission sets" do
      it "denies access when user has no roles" do
        user.roles.clear

        result = Writ::Access.authorization(context: user, action: :read, subject: asset)

        expect(result).not_to be_allowed
      end

      it "denies access when role has no permissions" do
        role.permissions.clear

        result = Writ::Access.authorization(context: user, action: :read, subject: asset)

        expect(result).not_to be_allowed
      end

      it "denies access when permissions exist but don't match action" do
        permission.update(action: 'update')  # Different action
        permission.update!(scopes: ['service_industry'])

        result = Writ::Access.authorization(context: user, action: :read, subject: asset)

        expect(result).not_to be_allowed
      end

      it "denies access when permissions exist but don't match model" do
        permission.update(model: 'User')  # Different model
        permission.update!(scopes: ['service_industry'])

        result = Writ::Access.authorization(context: user, action: :read, subject: asset)

        expect(result).not_to be_allowed
      end
    end

    describe "scope return type validation" do
      it "raises InvalidScopeError when scope returns non-relation" do
        registry = Writ::Configuration.registry
        registry.register_scope(model_name: 'Asset', scope_name: 'bad_scope') { "not a relation" }
        permission.update!(scopes: ['bad_scope'])

        begin
          expect {
            Writ::Access.filter(context: user, action: :read, records: Asset.all)
          }.to raise_error(Writ::InvalidScopeError, /must return an ActiveRecord::Relation/)
        ensure
          registry.remove_scope_callable(model_name: 'Asset', scope_name: 'bad_scope')
        end
      end

      it "raises InvalidScopeError when scope returns wrong model relation" do
        registry = Writ::Configuration.registry
        registry.register_scope(model_name: 'Asset', scope_name: 'wrong_model_scope') { User.all }
        permission.update!(scopes: ['wrong_model_scope'])

        begin
          expect {
            Writ::Access.filter(context: user, action: :read, records: Asset.all)
          }.to raise_error(Writ::InvalidScopeError, /must return a Asset relation/)
        ensure
          registry.remove_scope_callable(model_name: 'Asset', scope_name: 'wrong_model_scope')
        end
      end
    end

    describe "Current attributes edge cases" do
      it "works when Current is not set (all attributes nil)" do
        Current.reset

        # Use Role model — Asset scopes crash on nil Current.user
        edge_role = create(:role, organisation: organisation)
        role_permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['always_true_edge'])

        registry = Writ::Configuration.registry
        registry.register_condition(name: 'always_true_edge') { |context| true }

        begin
          # With Current.user nil, default scope filters to nil organisation = no results
          result = Writ::Access.authorization(context: user, action: :read, subject: edge_role)
          expect(result).not_to be_allowed
        ensure
          registry.remove_condition(name: 'always_true_edge')
        end
      end
    end
  end

  describe "instrumentation" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation, name: 'Test Role')
      r.permissions.clear
      r
    end
    let(:permission) { create(:permission, role: role, action: 'read', model: 'Asset', scopes: ['service_industry']) }
    let(:asset) { create(:asset, organisation: organisation) }

    before do
      user.roles << role
      permission # force creation
      Current.user = user
    end

    after { Current.reset }

    describe "permission.filter.writ event" do
      it "emits event when filtering records" do
        events = []
        subscriber = ActiveSupport::Notifications.subscribe('permission.filter.writ') do |*args|
          events << ActiveSupport::Notifications::Event.new(*args)
        end

        begin
          Writ::Access.filter(context: user, action: :read, records: Asset.all)

          expect(events.length).to eq(1)
          event = events.first

          expect(event.payload[:context_id]).to eq(user.id)
          expect(event.payload[:action]).to eq('read')
          expect(event.payload[:model]).to eq('Asset')
          expect(event.payload[:permissions_count]).to be_a(Integer)
          expect(event.payload[:valid_permissions_count]).to be_a(Integer)
          expect(event.payload[:duration_ms]).to be_a(Numeric)
          expect(event.payload[:duration_ms]).to be >= 0
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
      end

      it "includes conditions evaluated in payload" do
        events = []
        subscriber = ActiveSupport::Notifications.subscribe('permission.filter.writ') do |*args|
          events << ActiveSupport::Notifications::Event.new(*args)
        end

        # Add a condition to permission
        permission.update!(conditions: ['test_condition_for_instrumentation'])

        # Register the condition
        registry = Writ::Configuration.registry
        registry.register_condition(name: 'test_condition_for_instrumentation') { |context| true }

        begin
          Writ::Access.filter(context: user, action: :read, records: Asset.all)

          expect(events.length).to eq(1)
          event = events.first

          expect(event.payload[:conditions_evaluated]).to be_a(Array)
          expect(event.payload[:conditions_evaluated]).to include('test_condition_for_instrumentation')
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
          registry.remove_condition(name: 'test_condition_for_instrumentation')
        end
      end

      it "excludes missing conditions that were never invoked from telemetry" do
        events = []
        subscriber = ActiveSupport::Notifications.subscribe('permission.filter.writ') do |*args|
          events << ActiveSupport::Notifications::Event.new(*args)
        end
        original = Writ::Configuration.on_missing_condition
        permission.update!(conditions: ['missing_condition_for_instrumentation'])
        Writ::Configuration.on_missing_condition = :deny

        begin
          allow(Writ::Configuration.logger).to receive(:error)
          Writ::Access.filter(context: user, action: :read, records: Asset.all)

          expect(events.last.payload[:conditions_evaluated]).to eq([])
        ensure
          Writ::Configuration.on_missing_condition = original
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
      end

      it "includes scopes applied in payload" do
        events = []
        subscriber = ActiveSupport::Notifications.subscribe('permission.filter.writ') do |*args|
          events << ActiveSupport::Notifications::Event.new(*args)
        end

        begin
          Writ::Access.filter(context: user, action: :read, records: Asset.all)

          expect(events.length).to eq(1)
          event = events.first

          expect(event.payload[:scopes_applied]).to be_a(Array)
          expect(event.payload[:scopes_applied]).to include('service_industry')
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
      end

      it "shows valid_permissions_count less than permissions_count when conditions fail" do
        events = []
        subscriber = ActiveSupport::Notifications.subscribe('permission.filter.writ') do |*args|
          events << ActiveSupport::Notifications::Event.new(*args)
        end

        # Add a failing condition
        permission.update!(conditions: ['always_false_instrumentation'])

        # Register the condition to always return false
        registry = Writ::Configuration.registry
        registry.register_condition(name: 'always_false_instrumentation') { |context| false }

        begin
          Writ::Access.filter(context: user, action: :read, records: Asset.all)

          expect(events.length).to eq(1)
          event = events.first

          # Should have permissions but none valid due to failing condition
          expect(event.payload[:permissions_count]).to be > 0
          expect(event.payload[:valid_permissions_count]).to eq(0)
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
          registry.remove_condition(name: 'always_false_instrumentation')
        end
      end
    end

    describe "event subscription for audit logging" do
      it "allows subscribers to listen to permission filter events" do
        log = []

        subscriber = ActiveSupport::Notifications.subscribe('permission.filter.writ') do |name, start, finish, id, payload|
          log << {
            event: name,
            context_id: payload[:context_id],
            model: payload[:model],
            scopes: payload[:scopes_applied]
          }
        end

        begin
          Writ::Access.filter(context: user, action: :read, records: Asset.all)

          expect(log.length).to eq(1)
          expect(log.first[:event]).to eq('permission.filter.writ')
          expect(log.first[:context_id]).to eq(user.id)
          expect(log.first[:model]).to eq('Asset')
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
      end
    end
  end

  describe "symbol callable in scope" do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }
    let(:role) { create(:role, organisation: organisation) }
    let(:registry) { Writ::Configuration.registry }

    before do
      user.roles << role
      Current.user = user
    end

    after { Current.reset }

    it "evaluates a block-backed scope against the context" do
      # Define a method on the user that returns a relation
      user.define_singleton_method(:my_readable_roles) do
        Role.where(organisation_id: organisation_id)
      end

      registry.register_scope(model_name: 'Role', scope_name: 'symbol_scope') do |context|
        context.my_readable_roles
      end
      permission = create(:permission, role: role, model: 'Role', action: 'read', scopes: ['symbol_scope'])

      begin
        result = Writ::Access.filter(
          context: user, action: :read, records: Role.all
        )
        expect(result).to be_a(ActiveRecord::Relation)
        expect(result.where(organisation: organisation).count).to be >= 1
      ensure
        registry.remove_scope_callable(model_name: 'Role', scope_name: 'symbol_scope')
      end
    end
  end

  describe "scope callable arity flexibility" do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }
    let(:role) { create(:role, organisation: organisation) }
    let(:registry) { Writ::Configuration.registry }

    before do
      user.roles << role
      Current.user = user
      @original_asset_default_scope = registry.get_default_scope(model_name: 'Asset')
    end

    after do
      Current.reset
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'zero_param_scope')
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'one_param_scope')
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'zero_param')
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'one_param')

      # Restore original default scope instead of just deleting
      registry.remove_default_scope(model_name: 'Asset')
      if @original_asset_default_scope
        registry.register_default_scope(model_name: 'Asset') { |context| @original_asset_default_scope.call(context) }
      end
    end

    it "works with zero-parameter scopes" do
      # Register a zero-parameter scope (doesn't use context)
      registry.register_scope(model_name: 'Asset', scope_name: 'zero_param_scope') do
        Asset.where(status: :satisfactory)
      end

      # Create permission using this scope
      permission = create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['zero_param_scope'])

      # Create test assets
      good_asset = create(:asset, organisation: organisation, status: :satisfactory)
      bad_asset = create(:asset, organisation: organisation, status: :maintenance_required)

      # Filter should work with zero-param scope
      result = Writ::Access.filter(
        context: user,
        action: :read,
        records: Asset.all
      )

      expect(result).to include(good_asset)
      expect(result).not_to include(bad_asset)
    end

    it "works with one-parameter scopes" do
      # Register a one-parameter scope (uses context)
      registry.register_scope(model_name: 'Asset', scope_name: 'one_param_scope') do |context|
        Asset.joins(:service_industries)
             .where(service_industries: { id: context.service_industries })
      end

      # Create permission using this scope
      permission = create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['one_param_scope'])

      # Create service industries and assets
      user_industry = create(:service_industry)
      other_industry = create(:service_industry)
      user.service_industries << user_industry

      user_asset = create(:asset, organisation: organisation)
      user_asset.service_industries << user_industry

      other_asset = create(:asset, organisation: organisation)
      other_asset.service_industries << other_industry

      # Filter should work with one-param scope
      result = Writ::Access.filter(
        context: user,
        action: :read,
        records: Asset.all
      )

      expect(result).to include(user_asset)
      expect(result).not_to include(other_asset)
    end

    it "works with default_scope using zero parameters" do
      # Register a zero-parameter default scope
      registry.register_default_scope(model_name: 'Asset', replace: true) do
        Asset.where(status: :satisfactory)
      end

      # Create permission with no scopes (will use only default_scope)
      permission = create(:permission, role: role, model: 'Asset', action: 'read')

      # Create test assets
      good_asset = create(:asset, organisation: organisation, status: :satisfactory)
      bad_asset = create(:asset, organisation: organisation, status: :maintenance_required)

      # Filter should apply default_scope
      result = Writ::Access.filter(
        context: user,
        action: :read,
        records: Asset.all
      )

      expect(result).to include(good_asset)
      expect(result).not_to include(bad_asset)
    end

    it "works with default_scope using one parameter" do
      # Register a one-parameter default scope
      registry.register_default_scope(model_name: 'Asset', replace: true) do |context|
        Asset.where(organisation: context.organisation)
      end

      # Create permission with no scopes (will use only default_scope)
      permission = create(:permission, role: role, model: 'Asset', action: 'read')

      # Create test assets in different organisations
      user_asset = create(:asset, organisation: user.organisation)
      other_org = create(:organisation)
      other_asset = create(:asset, organisation: other_org)

      # Filter should apply default_scope
      result = Writ::Access.filter(
        context: user,
        action: :read,
        records: Asset.all
      )

      expect(result).to include(user_asset)
      expect(result).not_to include(other_asset)
    end

    it "combines zero-param and one-param scopes correctly" do
      # Register both types of scopes
      registry.register_scope(model_name: 'Asset', scope_name: 'zero_param') do
        Asset.where(status: :satisfactory)
      end

      registry.register_scope(model_name: 'Asset', scope_name: 'one_param') do |context|
        Asset.where(organisation: context.organisation)
      end

      # Create permission using both scopes
      permission = create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['zero_param', 'one_param'])

      # Create test assets
      good_user_asset = create(:asset, organisation: user.organisation, status: :satisfactory)
      bad_user_asset = create(:asset, organisation: user.organisation, status: :maintenance_required)
      other_org = create(:organisation)
      other_asset = create(:asset, organisation: other_org, status: :satisfactory)

      # Filter should combine both scopes with AND logic
      result = Writ::Access.filter(
        context: user,
        action: :read,
        records: Asset.all
      )

      expect(result).to include(good_user_asset)
      expect(result).not_to include(bad_user_asset) # Wrong status
      expect(result).not_to include(other_asset) # Wrong organisation
    end
  end

  describe "OR logic across roles" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:registry) { Writ::Configuration.registry }

    before { Current.user = user }
    after { Current.reset }

    it "ORs permissions across different roles" do
      role1 = create(:role, organisation: organisation, name: 'Role A')
      role1.permissions.clear
      role2 = create(:role, organisation: organisation, name: 'Role B')
      role2.permissions.clear

      # Role A: can read satisfactory assets
      registry.register_scope(model_name: 'Asset', scope_name: 'status_a') { Asset.where(status: :satisfactory) }
      perm_a = create(:permission, role: role1, model: 'Asset', action: 'read', scopes: ['status_a'])

      # Role B: can read maintenance_required assets
      registry.register_scope(model_name: 'Asset', scope_name: 'status_b') { Asset.where(status: :maintenance_required) }
      perm_b = create(:permission, role: role2, model: 'Asset', action: 'read', scopes: ['status_b'])

      user.roles << [role1, role2]

      sat_asset = create(:asset, organisation: organisation, status: :satisfactory)
      req_asset = create(:asset, organisation: organisation, status: :maintenance_required)
      rec_asset = create(:asset, organisation: organisation, status: :maintenance_recommended)

      result = Writ::Access.filter(context: user, action: :read, records: Asset.all)

      # User should see union of both roles' permissions
      expect(result).to include(sat_asset)
      expect(result).to include(req_asset)
      expect(result).not_to include(rec_asset)

      # Cleanup
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'status_a')
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'status_b')
    end
  end

  describe "merge_scopes preserves WHERE conditions (TEST-1)" do
    it "retains WHERE conditions from both base and scope queries" do
      base = Asset.where(status: :satisfactory)
      scope_query = Asset.where(organisation_id: 1)

      merged = Writ::Access::ScopeEvaluator.merge_scopes(base, scope_query)
      sql = merged.to_sql

      expect(sql).to include("status")
      expect(sql).to include("organisation_id")
    end
  end

  describe "strip_ordering_and_limits end-to-end" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end

    before { Current.user = user }
    after { Current.reset }

    it "strips ORDER, LIMIT, OFFSET from input relation and logs a warning" do
      role = create(:role, organisation: organisation)
      role.permissions.clear
      create(:permission, role: role, model: 'Asset', action: 'read')
      user.roles << role

      create(:asset, organisation: organisation, status: :satisfactory)
      create(:asset, organisation: organisation, status: :satisfactory)

      input = Asset.order(:name).limit(1).offset(1)

      expect(Writ::Configuration.logger).to receive(:warn).with(
        /Stripping ORDER, LIMIT, OFFSET.*Asset/
      ).at_least(:once)

      result = Writ::Access.filter(
        context: user, action: :read, records: input
      )

      # Result should not be constrained by the original LIMIT/OFFSET
      expect(result.limit_value).to be_nil
      expect(result.offset_value).to be_nil
      expect(result.order_values).to be_empty
    end
  end

  describe "convert_to_outer_joins prevents privilege reduction" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:registry) { Writ::Configuration.registry }

    before { Current.user = user }
    after { Current.reset }

    it "includes records without the joined association when ORing scoped and unscoped permissions" do
      # Create two roles: one with a joins(:service_industries) scope, one with no scopes
      scoped_role = create(:role, organisation: organisation, name: 'Scoped Join Role')
      scoped_role.permissions.clear
      unscoped_role = create(:role, organisation: organisation, name: 'Unscoped Join Role')
      unscoped_role.permissions.clear

      # Scoped role: can read assets filtered by service_industry
      si = create(:service_industry)
      registry.register_scope(model_name: 'Asset', scope_name: 'join_test_si') do |ctx|
        Asset.joins(:service_industries).where(service_industries: { id: si.id })
      end
      scoped_perm = create(:permission, role: scoped_role, model: 'Asset', action: 'read', scopes: ['join_test_si'])

      # Unscoped role: can read ALL assets (no scopes)
      create(:permission, role: unscoped_role, model: 'Asset', action: 'read')

      user.roles << [scoped_role, unscoped_role]

      # Create an asset WITH the association and one WITHOUT
      asset_with_si = create(:asset, organisation: organisation)
      asset_with_si.service_industries << si
      asset_without_si = create(:asset, organisation: organisation)

      result = Writ::Access.filter(
        context: user, action: :read, records: Asset.all
      )

      # Both assets should be accessible (unscoped role grants access to all)
      # Without INNER-to-LEFT-OUTER conversion, asset_without_si would be excluded
      expect(result).to include(asset_with_si)
      expect(result).to include(asset_without_si)
    ensure
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'join_test_si')
    end
  end

  describe "join_user_permissions_with_records with zero actions (TEST-2)" do
    let(:organisation) { create(:organisation) }

    it "raises ArgumentError when no actions are provided" do
      expect {
        Writ::Access.join_user_permissions_with_records(Role.all)
      }.to raise_error(ArgumentError, /at least one action/)
    end
  end

  describe "authorization class-level ignores scopes (TEST-5)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end

    before { Current.user = user }
    after { Current.reset }

    it "returns true for class-level check even when scopes would filter records" do
      permission = create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['service_industry'])
      user.roles << role

      # Class-level check should return true regardless of scope filtering
      result = Writ::Access.authorization(context: user, action: :read, subject: Asset)
      expect(result).to be_allowed
    end
  end

  describe "filter with Class argument (TEST-7)" do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }

    before { Current.user = user }
    after { Current.reset }

    it "creates a relation from a Class argument" do
      result = Writ::Access.filter(context: user, action: :read, records: Role)
      expect(result).to be_a(ActiveRecord::Relation)
    end
  end

  describe "authorization with empty relation (TEST-8)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end

    before { Current.user = user }
    after { Current.reset }

    it "returns true for an empty relation (vacuous truth)" do
      permission = create(:permission, role: role, model: 'Role', action: 'read')
      user.roles << role

      empty_relation = Role.where(id: -1)
      result = Writ::Access.authorization(context: user, action: :read, subject: empty_relation)
      expect(result).to be_allowed
    end
  end

  describe "potential_permissions multi-model grouping (TEST-12)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end

    it "groups permissions by model across multiple models" do
      create(:permission, role: role, model: 'Asset', action: 'read')
      create(:permission, role: role, model: 'Role', action: 'update')
      user.roles << role

      result = Writ::Access.potential_permissions(context: user)

      expect(result).to have_key('Asset')
      expect(result).to have_key('Role')
      expect(result['Asset']).to include('read' => true)
      expect(result['Role']).to include('update' => true)
    end
  end

  describe "on_missing_condition :deny for filter (TEST-16)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation, name: 'Deny Mode Role')
      r.permissions.clear
      r
    end

    before { Current.user = user }
    after { Current.reset }

    it "returns empty relation when condition is unregistered in :deny mode" do
      original_mode = Writ::Configuration.on_missing_condition

      begin
        Writ::Configuration.on_missing_condition = :deny

        permission = create(:permission, role: role, model: 'Role', action: 'read', conditions: ['deny_mode_where_test'])
        user.roles << role

        result = Writ::Access.filter(context: user, action: :read, records: Role.all)

        expect(result).to be_a(ActiveRecord::Relation)
        expect(result.count).to eq(0)
      ensure
        Writ::Configuration.on_missing_condition = original_mode
      end
    end
  end

  describe "default scope returning wrong type (TEST-18)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end
    let(:registry) { Writ::Configuration.registry }

    before do
      user.roles << role
      Current.user = user
      @original_default_scope = registry.get_default_scope(model_name: 'Asset')
    end

    after do
      registry.remove_default_scope(model_name: 'Asset')
      if @original_default_scope
        registry.register_default_scope(model_name: 'Asset') { |context| @original_default_scope.call(context) }
      end
      Current.reset
    end

    it "raises InvalidScopeError when default scope returns an array" do
      registry.register_default_scope(model_name: 'Asset', replace: true) { [1, 2, 3] }
      permission = create(:permission, role: role, model: 'Asset', action: 'read')

      expect {
        Writ::Access.filter(context: user, action: :read, records: Asset.all)
      }.to raise_error(Writ::InvalidScopeError, /must return an ActiveRecord::Relation/)
    end
  end

  describe "join_user_permissions_with_records boolean values (TEST-23)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation, name: 'Bool Test Role')
      r.permissions.clear
      r
    end

    before { Current.user = user }
    after { Current.reset }

    it "returns true/false boolean values for each action via virtual attributes" do
      create(:permission, role: role, model: 'Role', action: 'read')
      user.roles << role

      roles = organisation.roles
      result = Writ::Access.join_user_permissions_with_records(
        roles, :read, :delete, context: user
      )

      expect(result).to be_a(ActiveRecord::Relation)
      result.each do |record|
        expect(record.can_read).to be_in([true, false])
        expect(record.can_delete).to be_in([true, false])
      end
    end
  end

  describe "multiple scopes on same column" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end
    let(:registry) { Writ::Configuration.registry }

    before do
      user.roles << role
      Current.user = user
    end

    after do
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'status_good_or_recommended')
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'status_recommended_or_required')
      Current.reset
    end

    it "ANDs together multiple scopes that filter on the same column" do
      # Register two scopes that both filter on status with different values
      # Scope 1: Allows satisfactory OR maintenance_recommended
      registry.register_scope(model_name: 'Asset', scope_name: 'status_good_or_recommended') do
        Asset.where(status: [:satisfactory, :maintenance_recommended])
      end

      # Scope 2: Allows maintenance_recommended OR maintenance_required
      registry.register_scope(model_name: 'Asset', scope_name: 'status_recommended_or_required') do
        Asset.where(status: [:maintenance_recommended, :maintenance_required])
      end

      # Create permission using BOTH scopes
      permission = create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['status_good_or_recommended', 'status_recommended_or_required'])

      # Create test assets with different statuses
      satisfactory_asset = create(:asset, organisation: organisation, status: :satisfactory)
      recommended_asset = create(:asset, organisation: organisation, status: :maintenance_recommended)
      required_asset = create(:asset, organisation: organisation, status: :maintenance_required)

      # Filter assets - should only include the intersection of both scopes
      result = Writ::Access.filter(
        context: user,
        action: :read,
        records: Asset.all
      )

      # Scope 1 allows: [:satisfactory, :maintenance_recommended]
      # Scope 2 allows: [:maintenance_recommended, :maintenance_required]
      # Intersection (AND): [:maintenance_recommended]
      expect(result).to include(recommended_asset)
      expect(result).not_to include(satisfactory_asset) # Only in scope1, not scope2
      expect(result).not_to include(required_asset) # Only in scope2, not scope1
    end
  end

  describe "merge_scopes preserves JOINs (R24-TEST-1)" do
    it "carries JOINs from the scope query through merge" do
      base = Asset.where(status: :satisfactory)
      scope_query = Asset.joins(:service_industries).where(service_industries: { id: 1 })

      merged = Writ::Access::ScopeEvaluator.merge_scopes( base, scope_query)
      sql = merged.to_sql

      expect(sql).to include("JOIN")
      expect(sql).to include("service_industries")
      expect(sql).to include("status")
    end
  end

  describe "potential_permissions multi-role dedup (R24-TEST-2)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end

    it "deduplicates permissions across multiple roles" do
      role1 = create(:role, organisation: organisation)
      role1.permissions.clear
      role2 = create(:role, organisation: organisation)
      role2.permissions.clear

      create(:permission, role: role1, model: 'Asset', action: 'read')
      create(:permission, role: role2, model: 'Asset', action: 'read')
      user.roles << [role1, role2]

      result = Writ::Access.potential_permissions(context: user)
      expect(result['Asset']['read']).to eq(true)
    end
  end

  describe "default_scope is model-specific (TEST-R25-1)" do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }
    let(:registry) { Writ::Configuration.registry }

    before do
      Current.user = user
      user.roles << organisation.roles.find_by(name: 'Admin')
    end

    it "does not apply Asset default_scope when checking User permissions" do
      # Register a restrictive default scope for Asset only
      original = registry.get_default_scope(model_name: 'Asset')
      registry.register_default_scope(model_name: 'Asset', replace: true) do
        Asset.none
      end

      # User model should not be affected by Asset's default_scope
      result = Writ::Access.filter(
        context: user,
        action: :read,
        records: User.all
      )

      # Should return users (not empty), proving Asset default_scope wasn't applied
      expect(result).to include(user)
    ensure
      registry.remove_default_scope(model_name: 'Asset')
      register_default_scope_from(registry, 'Asset', original)
    end
  end

  describe "merge_scopes same-column AND verification (TEST-R26-1)" do
    it "ANDs same-column WHERE clauses instead of overwriting" do
      # Two queries on same column with non-overlapping values
      base = Asset.where(status: :satisfactory)
      scope_query = Asset.where(status: :maintenance_required)

      merged = Writ::Access::ScopeEvaluator.merge_scopes( base, scope_query)

      # If merge_scopes correctly ANDs, the intersection of {satisfactory} and {maintenance_required} is empty
      # If it overwrites (like .merge), it would return maintenance_required records
      expect(merged.to_a).to be_empty
    end
  end

  describe "merge_scopes bidirectional JOIN preservation (TEST-R26-2)" do
    it "preserves JOINs from both base and scope queries" do
      base = Asset.joins(:organisation).where(organisations: { id: 1 })
      scope_query = Asset.joins(:service_industries).where(service_industries: { id: 1 })

      merged = Writ::Access::ScopeEvaluator.merge_scopes( base, scope_query)
      sql = merged.to_sql

      expect(sql).to include("organisations")
      expect(sql).to include("service_industries")
    end
  end

  describe "OR logic across same-role permissions with different scopes (TEST-R26-3)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end
    let(:registry) { Writ::Configuration.registry }

    before { Current.user = user }
    after { Current.reset }

    it "ORs multiple permissions on the same role with different scope sets" do
      # Register two scopes that filter by different statuses
      registry.register_scope(model_name: 'Asset', scope_name: 'status_sat') do
        Asset.where(status: :satisfactory)
      end
      registry.register_scope(model_name: 'Asset', scope_name: 'status_req') do
        Asset.where(status: :maintenance_required)
      end

      # Create two permissions on the SAME role with different scopes
      perm1 = create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['status_sat'])
      perm2 = create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['status_req'])

      user.roles << role

      sat_asset = create(:asset, organisation: organisation, status: :satisfactory)
      req_asset = create(:asset, organisation: organisation, status: :maintenance_required)
      rec_asset = create(:asset, organisation: organisation, status: :maintenance_recommended)

      result = Writ::Access.filter(
        context: user, action: :read, records: Asset.all
      )

      # Should see union of both permissions' scope results
      expect(result).to include(sat_asset)
      expect(result).to include(req_asset)
      expect(result).not_to include(rec_asset)
    ensure
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'status_sat')
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'status_req')
    end
  end

  describe "caller-provided WHERE conditions survive permission filtering (TEST-R26-4)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end

    before { Current.user = user }
    after { Current.reset }

    it "preserves the original relation's WHERE conditions" do
      # Give user unrestricted read permission (no scopes)
      create(:permission, role: role, model: 'Asset', action: 'read')
      user.roles << role

      sat_asset = create(:asset, organisation: organisation, status: :satisfactory)
      req_asset = create(:asset, organisation: organisation, status: :maintenance_required)

      # Pass a pre-filtered relation
      result = Writ::Access.filter(
        context: user, action: :read, records: Asset.where(status: :satisfactory)
      )

      expect(result).to include(sat_asset)
      expect(result).not_to include(req_asset)
    end
  end

  describe "authorization with mixed permitted/non-permitted records (TEST-R26-11)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end
    let(:registry) { Writ::Configuration.registry }

    before { Current.user = user }
    after { Current.reset }

    it "returns false when relation contains both permitted and non-permitted records" do
      registry.register_scope(model_name: 'Asset', scope_name: 'only_satisfactory') do
        Asset.where(status: :satisfactory)
      end
      perm = create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['only_satisfactory'])
      user.roles << role

      permitted1 = create(:asset, organisation: organisation, status: :satisfactory)
      permitted2 = create(:asset, organisation: organisation, status: :satisfactory)
      non_permitted = create(:asset, organisation: organisation, status: :maintenance_required)

      # All three: should be false (one is non-permitted)
      expect(
        Writ::Access.authorization(
          context: user, action: :read, subject: Asset.where(id: [permitted1.id, permitted2.id, non_permitted.id])
        )
      ).not_to be_allowed

      # Only the two permitted: should be true
      expect(
        Writ::Access.authorization(
          context: user, action: :read, subject: Asset.where(id: [permitted1.id, permitted2.id])
        )
      ).to be_allowed
    ensure
      registry.remove_scope_callable(model_name: 'Asset', scope_name: 'only_satisfactory')
    end
  end

  describe ".declared_fields" do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user, organisation: organisation) }

    it "returns :all when context doesn't respond to roles" do
      context_obj = double("context")
      result = Writ::Access.declared_fields(context: context_obj, model: "Asset")
      expect(result).to eq(:all)
    end

    it "returns :all when no accessible_fields are defined for the model" do
      role = create(:role, organisation: organisation)
      user.roles << role

      result = Writ::Access.declared_fields(context: user, model: "Asset")
      expect(result).to eq(:all)
    end

    it "returns :all when any role has nil fields (unrestricted)" do
      role1 = create(:role, organisation: organisation, accessible_fields: { "Asset" => ["id", "name"] })
      role2 = create(:role, organisation: organisation, accessible_fields: { "Asset" => nil })
      user.roles << [role1, role2]

      result = Writ::Access.declared_fields(context: user, model: "Asset")
      expect(result).to eq(:all)
    end

    it "returns union of fields across multiple roles" do
      role1 = create(:role, organisation: organisation, accessible_fields: { "Asset" => ["id", "name"] })
      role2 = create(:role, organisation: organisation, accessible_fields: { "Asset" => ["id", "status", "cost"] })
      user.roles << [role1, role2]

      result = Writ::Access.declared_fields(context: user, model: "Asset")
      expect(result).to match_array(["id", "name", "status", "cost"])
    end

    it "returns specific fields for a single role" do
      role = create(:role, organisation: organisation, accessible_fields: { "Asset" => ["id", "name", "status"] })
      user.roles << role

      result = Writ::Access.declared_fields(context: user, model: "Asset")
      expect(result).to match_array(["id", "name", "status"])
    end

    it "returns empty array when all roles have empty fields" do
      role = create(:role, organisation: organisation, accessible_fields: { "Asset" => [] })
      user.roles << role

      result = Writ::Access.declared_fields(context: user, model: "Asset")
      expect(result).to eq([])
    end

    it "accepts a Class for the model parameter" do
      role = create(:role, organisation: organisation, accessible_fields: { "Asset" => ["id", "name"] })
      user.roles << role

      result = Writ::Access.declared_fields(context: user, model: Asset)
      expect(result).to match_array(["id", "name"])
    end

    it "scopes results to the specified model only" do
      role = create(:role, organisation: organisation, accessible_fields: { "Asset" => ["id", "name"], "User" => ["id", "email", "name"] })
      user.roles << role

      asset_result = Writ::Access.declared_fields(context: user, model: "Asset")
      user_result = Writ::Access.declared_fields(context: user, model: "User")

      expect(asset_result).to match_array(["id", "name"])
      expect(user_result).to match_array(["id", "email", "name"])
    end

    it "returns :all for nil context" do
      result = Writ::Access.declared_fields(context: nil, model: "Asset")
      expect(result).to eq(:all)
    end
  end

  describe "validate_action! sanitization (TEST-R25-4)" do
    it "sanitizes non-alphanumeric characters in error message" do
      expect {
        Writ::Access.authorization(
          context: nil,
          action: :"read<script>",
          subject: Asset.all
        )
      }.to raise_error(Writ::InvalidActionError, /readscript/)
    end

    it "accepts any well-formed action" do
      expect {
        Writ::Access.authorization(
          context: nil,
          action: :destroy,
          subject: Asset.all
        )
      }.not_to raise_error
    end
  end

  describe "GROUP BY scope validation (T1)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end

    before { Current.user = user }
    after { Current.reset }

    it "raises InvalidScopeError when scope returns a grouped relation" do
      registry = Writ::Configuration.registry
      registry.register_scope(model_name: 'Asset', scope_name: 'grouped_scope') do
        Asset.group(:status)
      end
      permission = create(:permission, role: role, model: 'Asset', action: 'read', scopes: ['grouped_scope'])
      user.roles << role

      begin
        expect {
          Writ::Access.filter(context: user, action: :read, records: Asset.all)
        }.to raise_error(Writ::InvalidScopeError, /must not return a grouped relation/)
      ensure
        registry.remove_scope_callable(model_name: 'Asset', scope_name: 'grouped_scope')
      end
    end
  end

  describe "on_condition_error = :raise (T2)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end

    before { Current.user = user }
    after { Current.reset }

    it "propagates errors when on_condition_error is :raise" do
      original_mode = Writ::Configuration.on_condition_error
      registry = Writ::Configuration.registry

      begin
        Writ::Configuration.on_condition_error = :raise

        permission = create(:permission, role: role, model: 'Asset', action: 'read', conditions: ['raise_mode_error'], scopes: ['organisation'])
        user.roles << role

        registry.register_condition(name: 'raise_mode_error') do |context|
          raise RuntimeError, "condition evaluation failed"
        end
        create(:asset, organisation: organisation)

        expect {
          Writ::Access.authorization(context: user, action: :read, subject: Asset.all)
        }.to raise_error(RuntimeError, "condition evaluation failed")
      ensure
        Writ::Configuration.on_condition_error = original_mode
        registry.remove_condition(name: 'raise_mode_error')
      end
    end
  end

  describe "Logger.error for :deny missing condition (T3)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end

    before { Current.user = user }
    after { Current.reset }

    it "logs an error when condition is unregistered in :deny mode" do
      original_mode = Writ::Configuration.on_missing_condition

      begin
        Writ::Configuration.on_missing_condition = :deny

        # Create an asset so the check has records to evaluate against
        asset = create(:asset, organisation: organisation)

        permission = create(:permission, role: role, model: 'Asset', action: 'read', conditions: ['unregistered_for_log_test'], scopes: ['organisation'])
        user.roles << role

        expect(Writ::Configuration.logger).to receive(:error).with(/Register it using/)

        result = Writ::Access.authorization(context: user, action: :read, subject: asset)
        expect(result).not_to be_allowed
      ensure
        Writ::Configuration.on_missing_condition = original_mode
      end
    end
  end

  describe "permission membership preserves explicit joins" do
    it "retains inner-join requirements in the membership subquery" do
      relation = Asset.joins(:service_industries).joins("INNER JOIN organisations ON organisations.id = assets.organisation_id")
      result = Writ::Access::ScopeEvaluator.merge_scopes(Asset.all, relation)
      expect(result.to_sql).to include('INNER JOIN "service_industries"')
      expect(result.to_sql).to include('INNER JOIN organisations')
      expect(result.to_sql).not_to include('LEFT OUTER JOIN')
    end
  end

  describe "strip_ordering_and_limits individual components (T-29)" do
    let(:evaluator) { Writ::Access::ScopeEvaluator }

    it "strips ORDER-only and warns" do
      relation = Asset.order(:name)
      expect(Writ::Configuration.logger).to receive(:warn).with(/Stripping ORDER/)
      result = evaluator.strip_ordering_and_limits(relation)
      expect(result.order_values).to be_empty
    end

    it "strips LIMIT-only and warns" do
      relation = Asset.limit(5)
      expect(Writ::Configuration.logger).to receive(:warn).with(/Stripping LIMIT/)
      result = evaluator.strip_ordering_and_limits(relation)
      expect(result.limit_value).to be_nil
    end

    it "strips OFFSET-only and warns" do
      relation = Asset.offset(10)
      expect(Writ::Configuration.logger).to receive(:warn).with(/Stripping OFFSET/)
      result = evaluator.strip_ordering_and_limits(relation)
      expect(result.offset_value).to be_nil
    end
  end

  describe "ConditionEvaluator truthiness semantics (T-36)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end
    let(:role) do
      r = create(:role, organisation: organisation)
      r.permissions.clear
      r
    end
    let(:registry) { Writ::Configuration.registry }

    before { Current.user = user }
    after { Current.reset }

    it "treats 0 as truthy (grants access) per Ruby semantics" do
      registry.register_condition(name: :returns_zero) { |_ctx| 0 }
      permission = create(:permission, role: role, model: 'Asset', action: 'read', conditions: ['returns_zero'])
      user.roles << role

      result = Writ::Access.authorization(context: user, action: :read, subject: Asset)
      expect(result).to be_allowed
    ensure
      registry.remove_condition(name: :returns_zero)
    end

    it "treats empty string as truthy (grants access) per Ruby semantics" do
      registry.register_condition(name: :returns_empty_string) { |_ctx| "" }
      permission = create(:permission, role: role, model: 'Asset', action: 'read', conditions: ['returns_empty_string'])
      user.roles << role

      result = Writ::Access.authorization(context: user, action: :read, subject: Asset)
      expect(result).to be_allowed
    ensure
      registry.remove_condition(name: :returns_empty_string)
    end

    it "denies access when condition returns nil" do
      registry.register_condition(name: :returns_nil) { |_ctx| nil }
      permission = create(:permission, role: role, model: 'Asset', action: 'read', conditions: ['returns_nil'])
      user.roles << role

      result = Writ::Access.authorization(context: user, action: :read, subject: Asset)
      expect(result).not_to be_allowed
    ensure
      registry.remove_condition(name: :returns_nil)
    end

    it "denies access when condition returns false" do
      registry.register_condition(name: :returns_false) { |_ctx| false }
      permission = create(:permission, role: role, model: 'Asset', action: 'read', conditions: ['returns_false'])
      user.roles << role

      result = Writ::Access.authorization(context: user, action: :read, subject: Asset)
      expect(result).not_to be_allowed
    ensure
      registry.remove_condition(name: :returns_false)
    end
  end

  describe "join_user_permissions_with_records with no permissions (T-39)" do
    let(:organisation) { create(:organisation) }
    let(:user) do
      u = create(:user, organisation: organisation)
      u.roles.clear
      u
    end

    before { Current.user = user }
    after { Current.reset }

    it "returns false for all can_<action> attributes when user has no permissions" do
      create(:role, organisation: organisation)
      create(:asset, organisation: organisation)

      roles = organisation.roles
      result = Writ::Access.join_user_permissions_with_records(
        roles, :read, :update, context: user
      )

      result.each do |record|
        expect(record.can_read).to eq(false)
        expect(record.can_update).to eq(false)
      end
    end
  end

  describe "authorization raises on unsaved records (E-13)" do
    it "raises ArgumentError for a new (unsaved) record" do
      asset = Asset.new(name: 'Unsaved')
      expect {
        Writ::Access.authorization(context: nil, action: :read, subject: asset)
      }.to raise_error(ArgumentError, /persisted record/)
    end
  end

  describe ".authorization and .validation dispatch" do
    let(:organisation) { create(:organisation) }
    let(:other_organisation) { create(:organisation, name: 'Other Authorization Org') }
    let(:user) { create(:user, organisation: organisation) }
    let(:role) { create(:role, organisation: organisation) }
    let(:allowed_record) { create(:role, organisation: organisation, name: 'Allowed Record') }
    let(:denied_record) { create(:role, organisation: other_organisation, name: 'Denied Record') }

    before do
      create(:permission, role: role, model: 'Role', action: 'read')
      user.roles << role
      Current.user = user
    end

    after { Current.reset }

    it 'authorizes one persisted subject through the saved database state' do
      decision = Writ::Access.authorization(
        subject: allowed_record,
        action: :read,
        context: user
      )

      expect(decision).to be_allowed
    end

    it 'requires every materialized saved subject to pass' do
      decision = Writ::Access.authorization(
        subject: [allowed_record, denied_record],
        action: :read,
        context: user
      )

      expect(decision).not_to be_allowed
    end

    it 'rejects a relation as a local validation subject' do
      expect {
        Writ::Access.validation(
          subject: Role.where(id: allowed_record.id),
          action: :read,
          context: user
        )
      }.to raise_error(ArgumentError, /relation|record/i)
    end

    it 'evaluates a materialized local subject without changing the saved API contract' do
      Writ::Configuration.on_missing_matcher = :skip

      decision = Writ::Access.validation(
        subject: allowed_record,
        action: :read,
        context: user
      )

      expect(decision).to be_allowed
    ensure
      Writ::Configuration.on_missing_matcher = :raise
    end

    it 'checks class grant availability without requiring a record' do
      decision = Writ::Access.authorization(
        subject: Role,
        action: :read,
        context: user
      )

      expect(decision).to be_allowed
    end

    it 'requires every record in a relation to pass saved authorization' do
      relation = Role.where(id: [allowed_record.id, denied_record.id])

      decision = Writ::Access.authorization(
        subject: relation,
        action: :read,
        context: user
      )

      expect(decision).not_to be_allowed
    end

    it 'accepts an empty saved collection as vacuously authorized' do
      decision = Writ::Access.authorization(
        subject: [],
        action: :read,
        context: user
      )

      expect(decision).to be_allowed
    end

    it 'accepts an empty saved relation without requiring a permission source' do
      decision = Writ::Access.authorization(
        subject: Role.where(id: -1),
        action: :read,
        context: Object.new
      )

      expect(decision).to be_allowed
      expect(decision.reason).to eq(:granted)
    end

    it 'accepts an empty saved relation with an empty permission source' do
      context = Struct.new(:permissions).new(Permission.none)

      decision = Writ::Access.authorization(
        subject: Role.where(id: -1),
        action: :read,
        context: context
      )

      expect(decision).to be_allowed
    end

    it 'does not evaluate grants for an empty saved relation' do
      FactoryBot.create(
        :permission,
        role: role,
        model: 'Role',
        action: 'read',
        conditions: ['missing_empty_relation_condition']
      )
      context = Struct.new(:permissions).new(role.permissions)

      decision = Writ::Access.authorization(
        subject: Role.where(id: -1),
        action: :read,
        context: context
      )

      expect(decision).to be_allowed
    end

    it 'does not treat a nonempty relation with limit zero as empty' do
      context = Struct.new(:permissions).new(Permission.none)

      decision = Writ::Access.authorization(
        subject: Role.where(id: allowed_record.id).limit(0),
        action: :read,
        context: context
      )

      expect(decision).not_to be_allowed
      expect(decision.reason).to eq(:no_grants)
    end

    it 'rejects grouped empty relations before checking emptiness' do
      expect {
        Writ::Access.authorization(
          subject: Role.where(id: -1).group(:name),
          action: :read,
          context: Object.new
        )
      }.to raise_error(ArgumentError, /grouped relations/)
    end

    it 'rejects new records in saved authorization' do
      expect {
        Writ::Access.authorization(
          subject: Role.new(organisation: organisation),
          action: :read,
          context: user
        )
      }.to raise_error(ArgumentError, /persisted|saved|record/i)
    end

    it 'rejects classes in local validation' do
      expect {
        Writ::Access.validation(subject: Role, action: :read, context: user)
      }.to raise_error(ArgumentError, /record|class/i)
    end

    it 'accepts an empty local collection as vacuously valid' do
      decision = Writ::Access.validation(subject: [], action: :read, context: user)

      expect(decision).to be_allowed
    end

    it 'denies a local collection when any proposed record fails its matcher' do
      registry = Writ::Configuration.registry
      original = registry.get_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original, replace: true,
                                  matches: ->(context, record) { record.organisation_id == context.organisation_id })

      decision = Writ::Access.validation(
        subject: [allowed_record, denied_record],
        action: :read,
        context: user
      )

      expect(decision).not_to be_allowed
    ensure
      registry.remove_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original)
    end

    it 'returns matcher denial details for a local record' do
      registry = Writ::Configuration.registry
      original = registry.get_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original, replace: true,
                                  matches: ->(_context, _record) { false })

      decision = Writ::Access.validation(
        subject: allowed_record,
        action: :read,
        context: user
      )

      expect(decision).not_to be_allowed
      expect(decision.reason).to eq(:proposed_scope_mismatch)
    ensure
      registry.remove_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original)
    end

    it 'keeps caller restrictions on a saved relation' do
      relation = Role.where(id: allowed_record.id).select(:id, :name)

      result = Writ::Access.authorization(
        subject: relation,
        action: :read,
        context: user
      )

      expect(result).to be_allowed
      expect(result.records).to all(have_attributes(id: allowed_record.id)) if result.respond_to?(:records)
    end

    it 'does not query target membership for local validation' do
      registry = Writ::Configuration.registry
      original = registry.get_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original, replace: true,
                                  matches: ->(context, record) { record.organisation_id == context.organisation_id })
      allowed_record
      sql = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _started, _finished, _id, payload|
        sql << payload[:sql].to_s
      end

      Writ::Access.validation(subject: allowed_record, action: :read, context: user)

      expect(sql).not_to include(a_string_matching(/SELECT .*FROM ["`]roles["`]/i))
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      registry.remove_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original)
    end

    it 'applies a common default scope once across multiple grant branches' do
      calls = 0
      registry = Writ::Configuration.registry
      original = registry.get_default_scope(model_name: 'Role')
      registry.register_default_scope(model_name: 'Role', replace: true) do |_context|
        calls += 1
        Role.all
      end
      second_role = create(:role, organisation: organisation, name: 'Second Grant Role')
      create(:permission, role: second_role, model: 'Role', action: 'read')
      user.roles << second_role

      decision = Writ::Access.authorization(
        subject: Role.where(id: allowed_record.id),
        action: :read,
        context: user
      )

      expect(decision).to be_allowed
      expect(calls).to eq(1)
    ensure
      registry.remove_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original)
    end

    it 'denies saved authorization when no grants exist' do
      user.roles.clear

      decision = Writ::Access.authorization(
        subject: allowed_record,
        action: :read,
        context: user
      )

      expect(decision).not_to be_allowed
      expect(decision.reason).to eq(:no_grants)
    end

    it 'allows saved authorization but denies a dirty local update when the matcher rejects' do
      create(:permission, role: role, model: 'Role', action: 'update')
      registry = Writ::Configuration.registry
      original = registry.get_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original, replace: true,
                                  matches: ->(_context, _record) { false })
      record = allowed_record
      record.name = 'Pending Name'

      expect(Writ::Access.authorization(subject: record, action: :update, context: user)).to be_allowed
      expect(Writ::Access.validation(subject: record, action: :update, context: user)).not_to be_allowed
    ensure
      registry.remove_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original)
    end

    it 'allows a local update when its matcher passes even if saved authorization denies it' do
      create(:permission, role: role, model: 'Role', action: 'update')
      registry = Writ::Configuration.registry
      original = registry.get_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original, replace: true,
                                  matches: ->(_context, _record) { true })
      record = denied_record
      record.name = 'Pending Name'

      expect(Writ::Access.authorization(subject: record, action: :update, context: user)).not_to be_allowed
      expect(Writ::Access.validation(subject: record, action: :update, context: user)).to be_allowed
    ensure
      registry.remove_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original)
    end

    it 'rejects local read validation for a new record' do
      expect {
        Writ::Access.validation(
          subject: Role.new(organisation: organisation), action: :read, context: user
        )
      }.to raise_error(ArgumentError, /create|new|persisted/i)
    end

    it 'runs creation validators for new local create validation' do
      create(:permission, role: role, model: 'Role', action: 'create')
      registry = Writ::Configuration.registry
      original = registry.get_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original, replace: true, matches: ->(_context, _record) { true })
      validators = Writ::Configuration.registry.instance_variable_get(:@creation_validators)
      snapshot = validators.transform_values(&:dup)
      validators.clear
      Writ::Configuration.register_creation_validator(model_name: 'Role') do |context:, record:|
        record.organisation_id == context.organisation_id
      end
      candidate = Role.new(organisation: organisation)

      expect(Writ::Access.validation(subject: candidate, action: :create, context: user)).to be_allowed
      candidate.organisation = other_organisation
      expect(Writ::Access.validation(subject: candidate, action: :create, context: user)).not_to be_allowed
    ensure
      validators.replace(snapshot) if validators && snapshot
      registry.remove_default_scope(model_name: 'Role') if registry
      register_default_scope_from(registry, 'Role', original)
      registry.remove_default_scope(model_name: 'Role') if registry
      register_default_scope_from(registry, 'Role', original)
    end

    it 'runs update validators for clean and dirty local update validation' do
      create(:permission, role: role, model: 'Role', action: 'update')
      registry = Writ::Configuration.registry
      original = registry.get_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original, replace: true, matches: ->(_context, _record) { true })
      validators = Writ::Configuration.registry.instance_variable_get(:@update_validators)
      snapshot = validators.transform_values(&:dup)
      validators.clear
      calls = []
      Writ::Configuration.register_update_validator(model_name: 'Role') do |context:, record:|
        calls << record.name
        context == user
      end
      record = allowed_record

      expect(Writ::Access.validation(subject: record, action: :update, context: user)).to be_allowed
      record.name = 'Pending Name'
      expect(Writ::Access.validation(subject: record, action: :update, context: user)).to be_allowed
      expect(calls).to eq(['Allowed Record', 'Pending Name'])
    ensure
      validators.replace(snapshot) if validators && snapshot
    end

    it 'uses one common default scope for the filtered relation across grant branches' do
      calls = 0
      registry = Writ::Configuration.registry
      original = registry.get_default_scope(model_name: 'Role')
      registry.register_default_scope(model_name: 'Role', replace: true) do |_context|
        calls += 1
        Role.all
      end
      second_role = create(:role, organisation: organisation, name: 'Second Filter Grant')
      create(:permission, role: second_role, model: 'Role', action: 'read')
      user.roles << second_role

      result = Writ::Access.filter(
        context: user, action: :read, records: Role.where(id: allowed_record.id)
      )

      expect(result).to include(allowed_record)
      expect(calls).to eq(1)
    ensure
      registry.remove_default_scope(model_name: 'Role')
      register_default_scope_from(registry, 'Role', original)
    end
  end
end
