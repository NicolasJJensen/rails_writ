require 'rails_helper'
require 'erb'

RSpec.describe 'Host integration regression contracts' do
  let(:registry) { Writ::Configuration.registry }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions, :roles, :id).new(role.permissions, Role.where(id: role.id), 123) }
  let!(:asset) { create(:asset, organisation: organisation) }

  before { Current.user = create(:user, organisation: organisation) }
  after do
    %w[contract_join contract_location contract_allowed].each { |name| registry.remove_scope_callable(model_name: 'Asset', scope_name: name) }
    registry.remove_condition(name: 'contract_retry')
    Current.reset
  end

  def grant(scopes = [])
    create(:permission, role: role, scopes: scopes)
  end

  it 'preserves existence-only joins' do
    registry.register_scope(model_name: 'Asset', scope_name: 'contract_join') { Asset.joins(:service_industries) }
    grant(['contract_join'])
    expect(Writ::Access.filter(context: context, action: :read, records: Asset)).to be_empty
  end

  it 'combines unjoined and joined grants in either insertion order' do
    registry.register_scope(model_name: 'Asset', scope_name: 'contract_join') { Asset.joins(:service_industries) }
    grant
    grant(['contract_join'])
    records = Asset.where(id: asset.id)
    expect(Writ::Access.filter(context: context, action: :read, records: records).pluck(:id)).to eq([asset.id])
  end

  it 'combines grants with different joins' do
    registry.register_scope(model_name: 'Asset', scope_name: 'contract_join') { Asset.joins(:service_industries) }
    registry.register_scope(model_name: 'Asset', scope_name: 'contract_location') { Asset.joins(:location) }
    grant(['contract_join'])
    grant(['contract_location'])
    records = Asset.where(id: asset.id)
    expect(Writ::Access.filter(context: context, action: :read, records: records).pluck(:id)).to eq([asset.id])
  end

  it 'does not skip forbidden rows when checking an offset relation' do
    allowed_id = asset.id
    registry.register_scope(model_name: 'Asset', scope_name: 'contract_allowed') { Asset.where(id: allowed_id) }
    grant(['contract_allowed'])
    create(:asset, organisation: organisation)
    expect(Writ::Access.authorization(context: context, action: :read, subject: Asset.order(:id).offset(1))).not_to be_allowed
  end

  it 'checks a projected collection' do
    grant
    subject = Asset.where(id: asset.id).select(:name)
    expect(Writ::Access.authorization(context: context, action: :read, subject: subject)).to be_allowed
  end

  it 'annotates without widening the caller projection' do
    grant
    subject = Asset.where(id: asset.id).select(:name)
    result = Writ::Access.join_user_permissions_with_records(subject, :read, context: context).first
    expect(result.name).to eq(asset.name)
    expect(result.attributes.keys).not_to include('description')
    expect(result.can_read).to be(true)
  end

  it 'uses the permission source supplied by a plain context for summaries' do
    grant
    expect(Writ::Access.potential_permissions(context: context)).to eq('Asset' => { 'read' => true })
  end

  it 'uses custom primary keys for persisted records and collections' do
    stub_const('ContractAsset', Class.new(ActiveRecord::Base) { self.table_name = 'assets'; self.primary_key = 'name' })
    create(:permission, role: role, model: 'ContractAsset')
    record = ContractAsset.find(asset.name)
    expect(Writ::Access.authorization(context: context, action: :read, subject: record)).to be_allowed
    expect(Writ::Access.authorization(context: context, action: :read, subject: ContractAsset.all)).to be_allowed
  end

  it 'retains restriction intent after a later host callback fails and save is retried' do
    registry.register_condition(name: 'contract_retry') { false }
    permission = grant
    callback = proc { raise 'host failure' }
    Permission.after_save(callback)
    begin
      expect { permission.update!(conditions: ['contract_retry']) }.to raise_error('host failure')
    ensure
      Permission.skip_callback(:save, :after, callback)
    end
    permission.save!
    expect(permission.reload.conditions).to eq(['contract_retry'])
  end

  it 'allows omitted required arguments as generation templates' do
    local = Writ::Logic::Registry.new
    local.register_condition(name: 'required_gate', arguments: { allow: { type: :boolean, required: true } }) { |_ctx, args| args[:allow] }
    local.register_permission(model: 'Asset', role: 'R', action: :read, scopes: [], conditions: ['required_gate'])
    expect { local.validate_references! }.not_to raise_error
  end

  it 'clears schemas when a parameterized rule is replaced' do
    local = Writ::Logic::Registry.new
    local.register_condition(name: 'gate', arguments: { allow: { type: :boolean } }) { |_ctx, args| args[:allow] }
    local.register_condition(name: 'gate', replace: true) { true }
    expect(local.condition_arguments_schema(name: 'gate')).to be_nil
    local.register_scope(model_name: 'Asset', scope_name: 'gate', arguments: { ids: { type: :array } }) { |_ctx, args| Asset.where(id: args[:ids]) }
    local.register_scope(model_name: 'Asset', scope_name: 'gate', replace: true) { Asset.all }
    expect(local.scope_arguments_schema(model_name: 'Asset', scope_name: 'gate')).to be_nil
  end

  it 'supports settings from the generated configuration DSL' do
    old = Writ::Configuration.on_missing_condition
    Writ.configure { |config| config.on_missing_condition = :deny }
    expect(Writ::Configuration.on_missing_condition).to eq(:deny)
  ensure
    Writ::Configuration.on_missing_condition = old
  end

  it 'preserves explicit model configuration across reset' do
    stub_const('ContractPermission', Class.new(Permission))
    old_registry = Writ::Configuration.registry
    old_blocks = Writ::Configuration.instance_variable_get(:@configure_blocks)&.dup
    Writ::Configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    Writ::Configuration.instance_variable_set(:@configure_blocks, [])
    Writ::Configuration.permission_class = ContractPermission
    Writ::Configuration.reset! {}
    expect(Writ::Configuration.permission_class).to eq(ContractPermission)
  ensure
    Writ::Configuration.permission_class = Permission
    Writ::Configuration.instance_variable_set(:@registry, old_registry)
    Writ::Configuration.instance_variable_set(:@configure_blocks, old_blocks)
  end
end
