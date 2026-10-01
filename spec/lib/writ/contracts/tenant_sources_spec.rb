require 'rails_helper'

RSpec.describe 'Tenant source selection' do
  let(:config) { Writ::Configuration }

  around do |example|
    settings = %i[scoping_model multi_tenant tenant_source role_source permission_source]
    originals = settings.to_h { |key| [key, config.public_send(key)] }
    example.run
  ensure
    originals.each { |key, value| config.public_send("#{key}=", value) }
    Current.reset
  end

  before do
    @tenant = create(:organisation)
    @other_tenant = create(:organisation)
    @actor = create(:user, organisation: @tenant)
    @role = create(:role, organisation: @tenant)
    @foreign_role = create(:role, organisation: @other_tenant)
    @actor.roles = [@role, @foreign_role]
    @permission = create(:permission, role: @role)
    @foreign_permission = create(:permission, role: @foreign_role)
    config.multi_tenant = nil
    config.scoping_model = Organisation
    config.tenant_source = ->(context) { context.organisation }
    config.role_source = nil
    config.permission_source = nil
  end

  it 'infers tenant mode from its model and resolves the persisted tenant from context' do
    expect(config.multi_tenant?).to be(true)
    expect(config.scoping_model).to eq('Organisation')
    expect(config.tenant_for(@actor)).to eq(@tenant)
    expect(config.roles_for(@actor)).to contain_exactly(@role)
    expect(config.permissions_for(@actor)).to contain_exactly(@permission)
  end

  it 'does not grant unassigned roles belonging to the selected tenant' do
    unassigned = create(:role, organisation: @tenant)
    create(:permission, role: unassigned)
    expect(config.roles_for(@actor)).to contain_exactly(@role)
    expect(config.permissions_for(@actor)).to contain_exactly(@permission)
  end

  ['', ' ', "\n\t"].each do |invalid|
    it "rejects a blank scoping model #{invalid.inspect} without disabling tenant mode" do
      expect { config.scoping_model = invalid }.to raise_error(ArgumentError, /scoping_model/)
      expect(config.scoping_model).to eq('Organisation')
      expect(config.multi_tenant?).to be(true)
      expect(config.permissions_for(@actor)).to contain_exactly(@permission)
    end
  end

  it 'uses the tenant association foreign key and association primary key' do
    stub_const('CustomSourceTenant', Class.new(ActiveRecord::Base) do
      self.table_name = 'organisations'
      self.primary_key = 'abn'
      has_many :roles, class_name: 'Role', foreign_key: :organisation_id, primary_key: :abn
    end)
    @tenant.update!(abn: @tenant.id.to_s)
    tenant = CustomSourceTenant.find(@tenant.abn)
    config.scoping_model = CustomSourceTenant
    config.tenant_source = ->(_context) { tenant }
    expect(config.roles_for(@actor)).to contain_exactly(@role)
    expect(config.permissions_for(@actor)).to contain_exactly(@permission)
  end

  it 'keeps the two source overrides independent' do
    config.role_source = ->(_context) { @actor.roles }
    expect(config.roles_for(@actor)).to contain_exactly(@role, @foreign_role)
    expect(config.permissions_for(@actor)).to contain_exactly(@permission)
    config.role_source = nil
    config.permission_source = ->(_context) { @actor.permissions }
    expect(config.roles_for(@actor)).to contain_exactly(@role)
    expect(config.permissions_for(@actor)).to contain_exactly(@permission, @foreign_permission)
  end

  it 'requires a tenant callback in tenant mode' do
    config.tenant_source = nil
    expect { config.roles_for(@actor) }.to raise_error(Writ::ConfigurationError, /tenant_source/)
    expect { config.permissions_for(@actor) }.to raise_error(Writ::ConfigurationError, /tenant_source/)
  end

  [nil, :wrong_model, :new_record, :destroyed_record].each do |invalid|
    it "fails closed for #{invalid.inspect} tenant results" do
      tenant = case invalid
               when :wrong_model then @actor
               when :new_record then Organisation.new
               when :destroyed_record then @other_tenant.tap(&:destroy!)
               end
      config.tenant_source = ->(_context) { tenant }
      expect { config.tenant_for(@actor) }.to raise_error(Writ::ConfigurationError, /persisted Organisation/)
      expect { config.roles_for(@actor) }.to raise_error(Writ::ConfigurationError)
      expect { config.permissions_for(@actor) }.to raise_error(Writ::ConfigurationError)
    end
  end

  it 'uses ordinary context associations when the model is unset' do
    config.scoping_model = nil
    config.tenant_source = ->(_context) { raise 'global mode must not resolve a tenant' }
    expect(config.multi_tenant?).to be(false)
    expect(config.tenant_for(@actor)).to be_nil
    expect(config.roles_for(@actor)).to contain_exactly(@role, @foreign_role)
    expect(config.permissions_for(@actor)).to contain_exactly(@permission, @foreign_permission)
  end

  it 'rejects global default generation and explicit permission migration in inferred tenant mode' do
    expect { Writ::Generator.generate_default_permissions }.to raise_error(Writ::ConfigurationError, /tenant/)
    migration = Writ::PermissionMigration.new(nil, [{ model: 'Asset', action: 'read' }], defaults: {
      'Reader' => { permissions: [{ model: 'Asset', action: 'read' }] }
    })
    expect { migration.apply }.to raise_error(Writ::ConfigurationError, /tenant/)
  end
end
