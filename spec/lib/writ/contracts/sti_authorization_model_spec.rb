require 'rails_helper'

RSpec.describe 'STI authorization model resolution' do
  let(:config) { Writ::Configuration }
  let(:access) { Writ::Access }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions, :roles, :organisation_id).new(role.permissions, Role.where(id: role.id), organisation.id) }

  around do |example|
    original_registry = config.registry
    original_resolver = config.authorization_model_resolver
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    example.run
  ensure
    config.instance_variable_set(:@registry, original_registry)
    config.authorization_model_resolver = original_resolver
    Current.reset
  end

  before do
    stub_const('StiAsset', Class.new(ActiveRecord::Base) do
      self.table_name = 'assets'
      self.inheritance_column = 'description'
    end)
    stub_const('StiTruck', Class.new(StiAsset))
    stub_const('StiVan', Class.new(StiAsset))
  end

  def grant(model: StiAsset, action: :read, fields: nil, scopes: [])
    role.update!(accessible_fields: { model.name => fields }) if fields
    create(:permission, role: role, model: model.name, action: action, scopes: scopes)
  end

  it 'keeps exact-model authorization by default and resolves an STI base only when opted in' do
    grant
    truck = create(:asset, organisation: organisation, description: 'StiTruck')
    expect(access.authorization(context: context, action: :read, subject: StiTruck.find(truck.id))).not_to be_allowed
    config.authorization_model_resolver = ->(model) { model.base_class }
    expect(access.authorization(context: context, action: :read, subject: StiTruck.find(truck.id))).to be_allowed
    expect(access.grant_available?(context: context, action: :read, model: StiTruck)).to be(true)
  end

  it 'preserves subtype and caller relation restrictions while using base grants' do
    grant
    truck = create(:asset, organisation: organisation, description: 'StiTruck', name: 'truck')
    create(:asset, organisation: organisation, description: 'StiVan', name: 'van')
    config.authorization_model_resolver = ->(model) { model.base_class }
    result = access.filter(context: context, action: :read, records: StiTruck.where(name: 'truck'))
    expect(result.map(&:id)).to eq([truck.id])
  end

  it 'uses the resolved base policy for fields and mixed STI batches without widening subtype queries' do
    grant(fields: { 'read' => ['name'] })
    truck = create(:asset, organisation: organisation, description: 'StiTruck')
    van = create(:asset, organisation: organisation, description: 'StiVan')
    resolver_calls = 0
    config.authorization_model_resolver = ->(model) { resolver_calls += 1; model.base_class }
    expect(access.readable_fields(context: context, record: StiTruck.find(truck.id))).to eq(['name'])
    expect(resolver_calls).to eq(1)
    expect(access.fields_for_many(context: context, action: :read,
                                  records: [StiTruck.find(truck.id), StiVan.find(van.id)])
           .values).to eq([['name'], ['name']])
  end

  it 'resolves field hooks against the authorization model for STI records' do
    config.authorization_model_resolver = ->(model) { model.base_class }
    grant(fields: { 'read' => ['name'] })
    config.register_field_resolver(model_name: 'StiAsset') { |fields:, **| fields + ['base_computed'] }
    config.register_field_resolver(model_name: 'StiTruck') { |fields:, **| fields + ['subtype_computed'] }
    truck = create(:asset, organisation: organisation, description: 'StiTruck')

    expect(access.readable_fields(context: context, record: StiTruck.find(truck.id))).to eq(['name', 'base_computed'])
  end

  it 'unions action-specific fields in model metadata' do
    config.authorization_model_resolver = ->(model) { model.base_class }
    role.update!(accessible_fields: { 'StiAsset' => { 'read' => ['name'], 'update' => ['description'] } })
    expect(access.declared_fields(context: context, model: StiTruck)).to contain_exactly('name', 'description')
  end

  it 'uses base policy matchers for saved and proposed STI updates' do
    config.authorization_model_resolver = ->(model) { model.base_class }
    config.register_default_scope(model_name: 'StiAsset', matches: ->(ctx, record) { record.organisation_id == ctx.organisation_id }) do |ctx|
      StiAsset.where(organisation_id: ctx.organisation_id)
    end
    grant(action: :update)
    truck = create(:asset, organisation: organisation, description: 'StiTruck')
    record = StiTruck.find(truck.id)
    record.organisation_id = organisation.id
    expect(access.authorization(context: context, action: :update, subject: record)).to be_allowed
    expect(access.validation(context: context, action: :update, subject: record)).to be_allowed
    record.organisation_id = organisation.id + 1
    expect(access.authorization(context: context, action: :update, subject: record)).to be_allowed
    expect(access.validation(context: context, action: :update, subject: record)).not_to be_allowed
  end

  it 'uses base-resolved creation and update validators for STI records' do
    config.authorization_model_resolver = ->(model) { model.base_class }
    create(:permission, role: role, model: 'StiAsset', action: :create)
    create(:permission, role: role, model: 'StiAsset', action: :update)
    creation_calls = 0
    update_calls = 0
    config.register_creation_validator(model_name: 'StiAsset') { |context:, record:| creation_calls += 1; true }
    config.register_update_validator(model_name: 'StiAsset') { |context:, record:| update_calls += 1; true }
    truck = create(:asset, organisation: organisation, description: 'StiTruck')

    expect(access.validation(context: context, action: :create, subject: StiTruck.new)).to be_allowed
    expect(creation_calls).to eq(1)
    expect(access.authorization(context: context, action: :update, subject: StiTruck.find(truck.id))).to be_allowed
    expect(access.validation(context: context, action: :update, subject: StiTruck.find(truck.id))).to be_allowed
    expect(update_calls).to eq(1)
  end

  it 'loads metadata and evaluates conditions once across mixed subtype batches, preserving denied records' do
    config.authorization_model_resolver = ->(model) { model.base_class }
    trucks = create_list(:asset, 2, organisation: organisation, description: 'StiTruck')
    van = create(:asset, organisation: organisation, description: 'StiVan')
    allowed_ids = [trucks.first.id, van.id]
    calls = 0
    config.register_condition(name: 'sti_gate') { calls += 1; true }
    config.register_scope(model_name: 'StiAsset', scope_name: 'selected') { StiAsset.where(id: allowed_ids) }
    permission = grant(fields: { 'read' => ['name'] }, scopes: ['selected'])
    permission.update!(conditions: ['sti_gate'])
    records = [StiTruck.find(trucks.first.id), StiVan.find(van.id), StiTruck.find(trucks.last.id)]
    sql = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      payload = args.last
      sql << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    result = ActiveRecord::Base.uncached { access.fields_for_many(context: context, action: :read, records: records) }
    expect(result).to eq(records[0] => ['name'], records[1] => ['name'], records[2] => [])
    expect(calls).to eq(1)
    expect(sql.grep(/FROM "permissions"/).length).to eq(1)
    expect(sql.grep(/FROM "assets"/).length).to eq(2)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'uses base scopes for annotations without exposing sibling subtype rows' do
    config.authorization_model_resolver = ->(model) { model.base_class }
    truck = create(:asset, organisation: organisation, description: 'StiTruck')
    create(:asset, organisation: organisation, description: 'StiVan')
    config.register_scope(model_name: 'StiAsset', scope_name: 'selected') { StiAsset.where(id: truck.id) }
    grant(scopes: ['selected'])
    records = access.join_user_permissions_with_records(StiTruck.all, :read, :delete, context: context).to_a
    expect(records.map(&:id)).to eq([truck.id])
    expect(records.first.attributes).to include('can_read' => true, 'can_delete' => false)
  end

  it 'does not accept a sibling scope relation for an exact-model grant' do
    config.register_scope(model_name: 'StiTruck', scope_name: 'wrong_model') { StiVan.all }
    grant(model: StiTruck, scopes: ['wrong_model'])
    expect { access.filter(context: context, action: :read, records: StiTruck) }.to raise_error(Writ::InvalidScopeError)
  end

  it 'returns unrestricted metadata when any declared action allows all fields' do
    role.update!(accessible_fields: { 'StiAsset' => { 'read' => ['name'], 'update' => nil } })
    expect(access.declared_fields(context: context, model: StiAsset)).to eq(:all)
  end

  it 'rejects resolver mappings to siblings or unrelated models' do
    expect { config.authorization_model_resolver = ->(_model) { StiVan }; config.authorization_model_for(StiTruck) }
      .to raise_error(Writ::ConfigurationError)
    stub_const('OtherAuthorizationModel', Class.new(ActiveRecord::Base) { self.table_name = 'organisations' })
    expect { config.authorization_model_resolver = ->(_model) { OtherAuthorizationModel }; config.authorization_model_for(StiTruck) }
      .to raise_error(Writ::ConfigurationError)
  end
end
