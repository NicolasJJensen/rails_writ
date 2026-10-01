require 'rails_helper'

RSpec.describe 'Approved authorization regressions' do
  let(:config) { Writ::Configuration }
  let(:access) { Writ::Access }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions).new(role.permissions) }

  around do |example|
    original_registry = config.registry
    settings = %i[multi_tenant scoping_model on_invalid_scope_arguments on_invalid_condition_arguments]
    originals = settings.to_h { |key| [key, config.public_send(key)] }
    example.run
  ensure
    originals.each { |key, value| config.public_send("#{key}=", value) }
    config.instance_variable_set(:@registry, original_registry)
    %w[approved_scope approved_mutation].each { |name| original_registry.remove_scope_callable(model_name: 'Asset', scope_name: name) }
    original_registry.remove_scope_callable(model_name: 'User', scope_name: 'approved_scope')
    %w[approved_condition approved_optional].each { |name| original_registry.remove_condition(name: name) }
    Current.reset
  end

  before { Current.user = build(:user, organisation: organisation) }

  it 'refuses global generation in tenant mode before changing an existing role' do
    config.multi_tenant = true
    role_name = role.name
    expect do
      Writ::Generator.generate_permissions(
        roles: [{ name: role_name }],
        permissions_by_role: { role_name => { permissions: [{ model: 'Asset', action: 'approve' }] } }
      )
    end.to raise_error(Writ::ConfigurationError, /tenant/i)
    expect(role.permissions.where(action: 'approve')).not_to exist
  end

  it 'does not resolve a tenant-owned role as global when only its model is configured' do
    config.multi_tenant = nil
    config.scoping_model = 'Organisation'
    role_name = role.name
    expect do
      Writ::Generator.generate_permissions(
        roles: [{ name: role_name }],
        permissions_by_role: { role_name => { permissions: [{ model: 'Asset', action: 'approve' }] } }
      )
    end.to raise_error(Writ::ConfigurationError, /tenant|scop/i)
    expect(role.permissions.where(action: 'approve')).not_to exist
  end

  it 'rejects parent model changes that retain incompatible scope attachments' do
    config.register_scope(model_name: 'Asset', scope_name: 'approved_scope') { Asset.none }
    permission = create(:permission, role: role, scopes: ['approved_scope'])
    expect(permission.update(model: 'User')).to be(false)
    expect(permission.errors[:model]).not_to be_empty
    expect(permission.reload.model).to eq('Asset')
  end

  it 'permits a model change when its old scopes are explicitly removed' do
    config.register_scope(model_name: 'Asset', scope_name: 'approved_scope') { Asset.none }
    permission = create(:permission, role: role, scopes: ['approved_scope'])
    permission.update!(model: 'User', scopes: [])
    expect(permission.reload.scopes).to eq([])
  end

  it 'fails closed on mismatched scope catalog models even after validation-bypassing writes' do
    config.register_scope(model_name: 'Asset', scope_name: 'approved_scope') { Asset.none }
    config.register_scope(model_name: 'User', scope_name: 'approved_scope') { User.all }
    permission = create(:permission, role: role, scopes: ['approved_scope'])
    permission.update_column(:model, 'User')
    expect { access.filter(context: context, action: :read, records: User).to_a }
      .to raise_error(Writ::ScopeValidationError, /model/i)
  end

  [:scope, :condition].each do |kind|
    it "denies malformed #{kind} JSON even without an argument schema" do
      name = "approved_#{kind}"
      if kind == :scope
        config.register_scope(model_name: 'Asset', scope_name: name) { Asset.all }
      else
        config.register_condition(name: name) { true }
      end
      permission = create(:permission, role: role, "#{kind}s" => [name])
      permission.public_send("permission_#{kind}s").first.update_column(:arguments, [])
      config.public_send("on_invalid_#{kind}_arguments=", :deny)
      create(:asset, organisation: organisation)
      expect(access.filter(context: context, action: :read, records: Asset)).to be_empty
    end

    [[], 'bad', 12, false].each do |invalid|
      it "denies malformed #{kind} JSON #{invalid.inspect} without discarding valid grants" do
        name = "approved_#{kind}"
        if kind == :scope
          config.register_scope(model_name: 'Asset', scope_name: name, arguments: { ids: { type: :array } }) { |_ctx, _args| Asset.all }
        else
          config.register_condition(name: name, arguments: { ids: { type: :array } }) { |_ctx, _args| true }
        end
        permission = create(:permission, role: role, "#{kind}s" => [name])
        permission.public_send("permission_#{kind}s").first.update_column(:arguments, invalid)
        config.public_send("on_invalid_#{kind}_arguments=", :deny)
        asset = create(:asset, organisation: organisation)
        expect(access.filter(context: context, action: :read, records: Asset)).to be_empty
        create(:permission, role: role)
        expect(access.filter(context: context, action: :read, records: Asset).pluck(:id)).to eq([asset.id])
        config.public_send("on_invalid_#{kind}_arguments=", :raise)
        expect { access.filter(context: context, action: :read, records: Asset) }
          .to raise_error(Writ::InvalidArgumentsError, /hash|object/i)
      end
    end
  end

  it 'gives each invocation independent mutable defaults, including nested array values' do
    schema = { label: { type: :string, default: +'original' }, items: { type: :array, default: [{ 'label' => +'nested' }] } }
    first = Writ::Logic::ArgumentValidator.validate!(schema: schema, arguments: {}, label: 'test')
    first[:label].replace('changed')
    first[:items].first['label'].replace('changed')
    second = Writ::Logic::ArgumentValidator.validate!(schema: schema, arguments: {}, label: 'test')
    expect(second).to eq('label' => 'original', 'items' => [{ 'label' => 'nested' }])
  end

  it 'does not mutate supplied arguments through the normalized callback values' do
    raw = { 'label' => +'original' }
    normalized = Writ::Logic::ArgumentValidator.validate!(schema: { label: { type: :string } }, arguments: raw, label: 'test')
    normalized[:label].replace('changed')
    expect(raw).to eq('label' => 'original')
  end

  it 'preserves optional defaults in a nonparameterized registered condition' do
    config.register_condition(name: 'approved_optional') { |_context, enabled = true| enabled }
    create(:permission, role: role, conditions: ['approved_optional'])
    expect(access.grant_available?(context: context, action: :read, model: Asset)).to be(true)
  end

  it 'preserves optional defaults in a nonparameterized registered scope' do
    config.register_scope(model_name: 'Asset', scope_name: 'approved_scope') do |_context, options = {}|
      Asset.where(status: options.fetch(:status, :satisfactory))
    end
    create(:permission, role: role, scopes: ['approved_scope'])
    asset = create(:asset, organisation: organisation)
    expect(access.filter(context: context, action: :read, records: Asset).pluck(:id)).to eq([asset.id])
  end

  it 'filters a derived relation using the normal model table alias' do
    asset = create(:asset, organisation: organisation)
    excluded = create(:asset, organisation: organisation)
    create(:permission, role: role)
    records = Asset.from(Asset.where(id: asset.id), :assets)
    expect(access.filter(context: context, action: :read, records: records).pluck(:id)).to eq([asset.id])
    expect(access.join_user_permissions_with_records(records, :read, context: context).first.can_read).to be(true)
    expect(access.authorization(context: context, action: :read, subject: records)).to be_allowed
    expect(excluded.id).not_to eq(asset.id)
  end
end
