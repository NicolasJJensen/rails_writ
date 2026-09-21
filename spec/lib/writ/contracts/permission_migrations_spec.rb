require 'rails_helper'

RSpec.describe 'Explicit permission data migrations' do
  let(:config) { Writ::Configuration }
  let(:generator) { Writ::Generator }
  let(:organisation) { create(:organisation) }

  around do |example|
    original = config.registry
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    organisation
    example.run
  ensure
    config.instance_variable_set(:@registry, original)
  end

  def define_defaults
    config.register_permission(model: 'Asset', role: 'Admin', action: :update, scopes: [])
    config.register_permission(model: 'Asset', role: 'Admin', action: :approve, scopes: [])
    config.register_accessible_fields(model: 'Asset', role: 'Admin', fields: ['name'], action: :approve)
    generator.generate_default_permissions(organisation)
  end

  it 'is idempotent and preserves customized grants, fields, descriptions and the default role' do
    define_defaults
    role = organisation.roles.find_by!(name: 'Admin')
    existing = role.permissions.find_by!(model: 'Asset', action: 'update')
    # The temporary registry must know this existing scope during writes.
    config.register_scope(model_name: 'Asset', scope_name: 'active') { Asset.where(status: :satisfactory) }
    existing.update!(scopes: ['active'])
    role.update!(description: 'Custom', accessible_fields: { 'Asset' => { 'update' => ['description'] } })
    original_default = organisation.default_role_id
    2.times { generator.add_permissions(organisation, permissions: [{ model: Asset, action: :approve }]) }
    expect(role.permissions.where(model: 'Asset', action: 'approve').count).to eq(1)
    expect(role.permissions.where(model: 'Asset', action: 'update').count).to eq(1)
    expect(existing.reload.scopes).to eq(['active'])
    expect(role.reload.accessible_fields).to eq('Asset' => { 'update' => ['description'] })
    expect(role.description).to eq('Custom')
    expect(organisation.reload.default_role_id).to eq(original_default)
  end

  it 'does not add a default over an existing customized action' do
    define_defaults
    role = organisation.roles.find_by!(name: 'Admin')
    before = role.permissions.where(model: 'Asset', action: 'update').pluck(:id)
    role.update!(accessible_fields: { 'Asset' => [] })
    generator.add_permissions(organisation, permissions: [{ model: 'Asset', action: :update }])
    expect(role.permissions.where(model: 'Asset', action: 'update').pluck(:id)).to eq(before)
    expect(role.reload.accessible_fields).to eq('Asset' => [])
  end

  it 'rejects unknown or empty selections before changing any organisation' do
    define_defaults
    expect { generator.add_permissions(organisation, permissions: []) }.to raise_error(ArgumentError)
    expect { generator.add_permissions(organisation, permissions: [{ model: Asset, action: :missing }]) }.to raise_error(ArgumentError)
  end

  it 'refuses full default generation for an existing organisation' do
    define_defaults
    expect { generator.generate_default_permissions(organisation) }.to raise_error(Writ::ConfigurationError, /add_permissions/)
  end

  it 'adds all alternative grants for a new action together' do
    define_defaults
    config.register_scope(model_name: 'Asset', scope_name: 'active') { Asset.where(status: :satisfactory) }
    config.register_scope(model_name: 'Asset', scope_name: 'archived') { Asset.where(archived: true) }
    config.register_permission(model: 'Asset', role: 'Admin', action: :publish, scopes: ['active'])
    config.register_permission(model: 'Asset', role: 'Admin', action: :publish, scopes: ['archived'])
    expect(organisation.roles.find_by!(name: 'Admin').permissions.where(model: 'Asset', action: 'publish').count).to eq(0)
    generator.add_permissions(organisation, permissions: [{ model: Asset, action: :publish }])
    expect(organisation.roles.find_by!(name: 'Admin').permissions.where(model: 'Asset', action: 'publish').count).to eq(2)
  end

  it 'applies per-run condition arguments without mutating registered defaults' do
    config.register_condition(name: 'tenant_gate', arguments: { ids: { type: :array, required: true } }) do |_context, _args|
      true
    end
    config.register_permission(model: 'Asset', role: 'Admin', action: :publish, scopes: [], conditions: [:tenant_gate])

    generator.add_permissions(
      organisation,
      permissions: [{ model: Asset, action: :publish }],
      condition_arguments: { tenant_gate: { ids: [organisation.id] } }
    )

    permission = organisation.roles.find_by!(name: 'Admin').permissions.find_by!(action: 'publish')
    expect(permission.condition_arguments).to eq('tenant_gate' => { 'ids' => [organisation.id] })
    expect(config.registry.all_permissions.dig('Admin', 'Asset').first[:condition_arguments]).to eq({})
  end

  it 'does not add configured alternatives to an existing customized action' do
    define_defaults
    generator.add_permissions(organisation, permissions: [{ model: Asset, action: :approve }])
    config.register_scope(model_name: 'Asset', scope_name: 'active') { Asset.where(status: :satisfactory) }
    role = organisation.roles.find_by!(name: 'Admin')
    role.permissions.find_by!(model: 'Asset', action: 'approve').update!(scopes: ['active'])
    expect { generator.add_permissions(organisation, permissions: [{ model: Asset, action: :approve }]) }
      .not_to change { role.reload.permissions.where(model: 'Asset', action: 'approve').count }
  end
end
