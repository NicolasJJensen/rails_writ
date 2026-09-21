require 'rails_helper'
require 'rake'

RSpec.describe 'Permission lifecycle preservation' do
  let(:config) { Writ::Configuration }
  let(:generator) { Writ::Generator }
  let(:access) { Writ::Access }

  around do |example|
    registry = config.registry
    field_default = config.field_default
    old_rake = Rake.application
    old_env = ENV.to_h.slice('CONFIRM', 'DRY_RUN')
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    config.field_default = :all
    example.run
  ensure
    config.instance_variable_set(:@registry, registry)
    config.field_default = field_default
    Rake.application = old_rake
    %w[CONFIRM DRY_RUN].each { |key| old_env.key?(key) ? ENV[key] = old_env[key] : ENV.delete(key) }
    Current.reset
  end

  def configured_role(fields: ['name'])
    config.configure { permission :read, model: Asset, role: :Reviewer }
    organisation = create(:organisation)
    role = organisation.roles.find_by!(name: 'Reviewer')
    role.update!(accessible_fields: { 'Asset' => fields }, generated_fields: { 'Asset' => fields })
    role
  end

  # Restrict every cleanup model to this example's records. No other tenant can be touched.
  def cleanup_for(role)
    allow(config).to receive(:role_class).and_return(Role.where(id: role.id))
    allow(config).to receive(:scope_class).and_return(Scope.none)
    allow(config).to receive(:condition_class).and_return(Condition.none)
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path('../../../lib/tasks/writ.rake', __dir__)
    ENV['CONFIRM'] = '1'
    ENV.delete('DRY_RUN')
    Rake::Task['writ:cleanup'].invoke
  end

  def retire_read
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    config.configure { permission :read, model: User, role: :Reviewer }
  end

  [ ['name'], { 'read' => ['name'], 'update' => ['description'] } ].each do |fields|
    it "preserves #{fields.class} field restrictions used by a surviving custom grant" do
      role = configured_role(fields: fields)
      custom = role.permissions.create!(model: 'Asset', action: 'update')
      actor = Struct.new(:permissions).new(role.permissions)
      asset = create(:asset, organisation: role.organisation)
      before = access.writable_fields(context: actor, record: asset)
      retire_read
      cleanup_for(role)
      expect(Permission.exists?(custom.id)).to be(true)
      expect(role.permissions.where(model: 'Asset', action: 'read')).not_to exist
      expect(role.reload.accessible_fields['Asset']).to eq(fields)
      expect(access.writable_fields(context: actor, record: asset)).to eq(before)
    end
  end

  it 'preserves field restrictions used by an unchanged configured generated grant' do
    role = configured_role
    grant_id = role.permissions.first.id
    # The grant remains configured; only its field declaration is absent.
    cleanup_for(role)
    expect(Permission.exists?(grant_id)).to be(true)
    expect(role.reload.accessible_fields['Asset']).to eq(['name'])
  end

  it 'retires obsolete tracked grants and fields when no grant depends on them' do
    role = configured_role
    retire_read
    cleanup_for(role)
    expect(role.permissions.where(model: 'Asset')).not_to exist
    expect(role.reload.accessible_fields).not_to have_key('Asset')
    expect(role.generated_fields).not_to have_key('Asset')
  end

  it 'preserves generated grants and restrictions when a tenant renames a role' do
    role = configured_role
    ids = role.permissions.pluck(:id)
    role.update!(name: 'Tenant-owned display name')
    cleanup_for(role)
    expect(role.permissions.pluck(:id)).to eq(ids)
    expect(role.reload.accessible_fields['Asset']).to eq(['name'])
  end

  it 'rechecks a role rename between preview and deletion' do
    role = configured_role
    ids = role.permissions.pluck(:id)
    retire_read
    allow(generator).to receive(:stale_items).and_wrap_original do |method, *args|
      candidates = method.call(*args)
      role.update!(name: 'Renamed after preview')
      candidates
    end
    cleanup_for(role)
    expect(role.permissions.pluck(:id)).to eq(ids)
    expect(role.reload.accessible_fields['Asset']).to eq(['name'])
  end

  it 'does not delete a stale grant after the host renames it to a configured role' do
    role = configured_role
    grant_id = role.permissions.first.id
    retire_read
    config.configure { permission :read, model: Asset, role: :ConfiguredRole }
    allow(generator).to receive(:stale_items).and_wrap_original do |method, *args|
      candidates = method.call(*args)
      role.update!(name: 'ConfiguredRole')
      candidates
    end

    cleanup_for(role)

    expect(Permission.exists?(grant_id)).to be(true)
  end

  it 'does not delete a stale field after the host renames it to a configured role' do
    role = configured_role
    retire_read
    role.permissions.destroy_all
    config.configure do
      permission :read, model: Asset, role: :ConfiguredRole
      accessible_fields [:name], model: Asset, role: :ConfiguredRole
    end
    allow(generator).to receive(:stale_items).and_wrap_original do |method, *args|
      candidates = method.call(*args)
      role.update!(name: 'ConfiguredRole')
      candidates
    end

    cleanup_for(role)

    expect(role.reload.accessible_fields['Asset']).to eq(['name'])
  end

  it 'rechecks surviving grants introduced after preview before deleting fields' do
    role = configured_role
    retire_read
    allow(generator).to receive(:stale_items).and_wrap_original do |method, *args|
      candidates = method.call(*args)
      role.permissions.create!(model: 'Asset', action: 'update')
      candidates
    end
    cleanup_for(role)
    expect(role.reload.accessible_fields['Asset']).to eq(['name'])
  end

  it 'creates a tenant after repeated setup and does not duplicate inherited initialization' do
    config.configure { permission :read, model: Asset, role: :Reviewer }
    stub_const('LifecycleTenant', Class.new(ActiveRecord::Base) do
      self.table_name = 'organisations'
      include Writ::Roleable
      as_roleable(scoping_model: true)
      as_roleable(scoping_model: true)
      has_many :roles, foreign_key: :organisation_id
    end)
    stub_const('LifecycleChildTenant', Class.new(LifecycleTenant))
    LifecycleChildTenant.as_roleable(scoping_model: true)
    tenant = LifecycleChildTenant.create!(name: 'Idempotent setup')
    expect(tenant.roles.pluck(:name)).to eq(['Reviewer'])
    expect(tenant.roles.first.permissions.count).to eq(1)
    expect { LifecycleTenant.as_roleable(scoping_model: false) }.to raise_error(ArgumentError, /already set/)
    expect { LifecycleChildTenant.as_roleable(scoping_model: true, auto_generate: false) }.to raise_error(ArgumentError, /already set/)
  end
end
