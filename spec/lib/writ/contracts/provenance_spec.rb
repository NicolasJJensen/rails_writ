require 'rails_helper'

RSpec.describe 'Generated default provenance' do
  let(:organisation) { create(:organisation) }
  let(:registry) { Writ::Configuration.registry }

  it 'does not mark custom permissions on a built-in role for cleanup' do
    role = organisation.roles.find_by!(name: 'Admin')
    permission = create(:permission, role: role, action: :approve)
    stale = Writ::Generator.stale_items(registry)
    expect(stale.filter_map { |item| item[:record] }).not_to include(permission)
  end

  it 'preserves customized fields when full generation is rejected' do
    role = organisation.roles.find_by!(name: 'Admin')
    role.update!(accessible_fields: role.accessible_fields.merge('Asset' => ['name']))
    expect { Writ::Generator.generate_default_permissions(organisation) }.to raise_error(Writ::ConfigurationError)
    expect(role.reload.accessible_fields['Asset']).to eq(['name'])
  end

  it 'does not remove a generated permission after the host customizes it' do
    permission = organisation.roles.find_by!(name: 'Admin').permissions.find_by!(model: 'Asset', action: 'read')
    permission.update!(scopes: ['status_active'])
    stale = Writ::Generator.stale_items(registry)
    expect(stale.filter_map { |item| item[:record] }).not_to include(permission)
  end
end
