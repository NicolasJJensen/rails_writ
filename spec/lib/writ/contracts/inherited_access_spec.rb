require 'rails_helper'

RSpec.describe 'Inherited authorization decisions' do
  let(:config) { Writ::Configuration }
  let(:access) { Writ::Access }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:user) { create(:user, organisation: organisation).tap { |actor| actor.roles << role } }

  around do |example|
    original = config.registry
    resolver = config.authorization_model_resolver
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    config.authorization_model_resolver = nil
    example.run
  ensure
    config.instance_variable_set(:@registry, original)
    config.authorization_model_resolver = resolver
  end

  before do
    stub_const('FleetVehicle', Class.new(ActiveRecord::Base) do
      self.table_name = 'assets'
      self.inheritance_column = 'description'
    end)
    stub_const('FleetTruck', Class.new(FleetVehicle))
    stub_const('FleetVan', Class.new(FleetVehicle))
    stub_const('FleetHeavyTruck', Class.new(FleetTruck))
    config.register_model_inheritance(model_name: 'FleetTruck', parent_model_name: 'FleetVehicle')
    config.register_model_inheritance(model_name: 'FleetVan', parent_model_name: 'FleetVehicle')
    config.register_model_inheritance(model_name: 'FleetHeavyTruck', parent_model_name: 'FleetTruck')
  end

  def vehicle(type = FleetVehicle, **attributes)
    type.create!({ name: 'Allowed', organisation_id: organisation.id }.merge(attributes))
  end

  def grant(model: FleetVehicle, action: :read, scopes: [], conditions: [])
    create(:permission, role: role, model: model.name, action: action, scopes: scopes, conditions: conditions)
  end

  def boundary(model, name)
    config.register_default_scope(model_name: model.name,
      validate: ->(record, errors) { errors.add(:name, :not_permitted) unless record.name == name }) do
      model.where(name: name)
    end
  end

  it 'shares parent stored grants without adding rows for subclasses' do
    grant
    records = [vehicle, vehicle(FleetVan), vehicle(FleetTruck), vehicle(FleetHeavyTruck)]
    records.each { |record| expect(access.authorization(subject: record, action: :read, context: user)).to be_allowed }
    expect(access.filter(records: FleetVehicle, action: :read, context: user)).to match_array(records)
    expect(role.permissions.pluck(:model)).to eq(['FleetVehicle'])
  end

  it 'includes child grants in base queries without granting access to siblings or ancestors' do
    grant(model: FleetTruck)
    vehicle
    vehicle(FleetVan)
    truck = vehicle(FleetTruck)
    heavy = vehicle(FleetHeavyTruck)
    expect(access.filter(records: FleetVehicle, action: :read, context: user)).to match_array([truck, heavy])
    expect(access.authorization(subject: FleetVehicle.where(id: truck.id), action: :read, context: user)).to be_allowed
    expect(access.authorization(subject: FleetVehicle.all, action: :read, context: user)).not_to be_allowed
    expect(access.filter(records: FleetVan, action: :read, context: user)).to be_empty
  end

  it 'cannot bypass a child boundary through a broad ancestor branch' do
    grant
    boundary(FleetTruck, 'Allowed')
    van = vehicle(FleetVan, name: 'Other')
    allowed = vehicle(FleetTruck)
    blocked = vehicle(FleetTruck, name: 'Other')
    blocked_heavy = vehicle(FleetHeavyTruck, name: 'Other')
    expect(access.filter(records: FleetVehicle, action: :read, context: user)).to match_array([van, allowed])
    [blocked, blocked_heavy].each do |record|
      expect(access.authorization(subject: record, action: :read, context: user)).not_to be_allowed
    end
    rows = access.join_user_permissions_with_records(FleetVehicle.all, :read, context: user).index_by(&:id)
    expect(rows[blocked.id].attributes['can_read']).to be(false)
    expect(rows[van.id].attributes['can_read']).to be(true)
  end

  it 'intersects parent and child default scopes for saved and proposed records' do
    grant(action: :update)
    config.register_default_scope(model_name: 'FleetVehicle',
      validate: ->(record, errors) { errors.add(:organisation_id, :not_permitted) unless record.organisation_id == organisation.id }) do
      FleetVehicle.where(organisation_id: organisation.id)
    end
    boundary(FleetTruck, 'Allowed')
    truck = vehicle(FleetTruck)
    expect(access.validation(subject: truck, action: :update, context: user)).to be_allowed
    truck.name = 'Rejected'
    expect(access.validation(subject: truck, action: :update, context: user).errors.map(&:attribute)).to include(:name)
    truck.name = 'Allowed'
    truck.organisation_id = organisation.id + 100
    expect(access.validation(subject: truck, action: :update, context: user).errors.map(&:attribute)).to include(:organisation_id)
  end

  it 'runs both callbacks of an inherited parameterized scope with attachment arguments' do
    config.register_scope(model_name: 'FleetVehicle', scope_name: 'named',
      arguments: { name: { type: :string, required: true } },
      validate: ->(record, errors, arguments:) { errors.add(:name, :not_permitted) unless record.name == arguments[:name] }) do |_, arguments|
      FleetVehicle.where(name: arguments[:name])
    end
    grant(model: FleetTruck, action: :update, scopes: [{ named: { name: 'Allowed' } }])
    truck = vehicle(FleetTruck)
    expect(access.authorization(subject: truck, action: :update, context: user)).to be_allowed
    expect(access.validation(subject: truck, action: :update, context: user)).to be_allowed
    truck.name = 'Denied'
    expect(access.validation(subject: truck, action: :update, context: user)).not_to be_allowed
  end

  it 'keeps parent permissions pinned to parent scopes when a child replaces a name' do
    config.register_scope(model_name: 'FleetVehicle', scope_name: 'named') { FleetVehicle.where(name: 'Parent') }
    config.register_scope(model_name: 'FleetTruck', scope_name: 'named', replace: true) { FleetTruck.where(name: 'Child') }
    grant(scopes: [:named])
    parent = vehicle(FleetTruck, name: 'Parent')
    child = vehicle(FleetTruck, name: 'Child')
    expect(access.filter(records: FleetTruck, action: :read, context: user)).to eq([parent])
    grant(model: FleetTruck, scopes: [:named])
    expect(access.filter(records: FleetTruck, action: :read, context: user)).to match_array([parent, child])
  end

  it 'preserves caller filters and concrete subtype restrictions' do
    grant
    selected = vehicle(FleetTruck, name: 'Selected')
    vehicle(FleetTruck)
    vehicle(FleetVan, name: 'Selected')
    expect(access.filter(records: FleetTruck.where(name: 'Selected'), action: :read, context: user)).to eq([selected])
  end

  it 'does not grant unregistered or unloaded subclasses through an ancestor collection' do
    stub_const('FleetBicycle', Class.new(FleetVehicle))
    stub_const('FleetSpecialTruck', Class.new(FleetTruck))
    grant
    bicycle = vehicle(FleetBicycle)
    special = vehicle(FleetSpecialTruck)
    unknown = vehicle
    unknown.update_column(:description, 'FleetUnloadedVehicle')
    truck = vehicle(FleetTruck)
    expect(access.filter(records: FleetVehicle, action: :read, context: user).pluck(:id)).to eq([truck.id])
    expect(access.filter(records: FleetTruck, action: :read, context: user).pluck(:id)).to eq([truck.id])
    [bicycle, special].each do |record|
      expect(access.authorization(subject: record, action: :read, context: user)).not_to be_allowed
    end
    grant(model: FleetBicycle)
    expect(access.filter(records: FleetVehicle, action: :read, context: user).pluck(:id)).to match_array([truck.id, bicycle.id])
  end

  it 'retains exact-model isolation when no inheritance relationship is registered' do
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    grant
    parent = vehicle
    van = vehicle(FleetVan)
    expect(access.filter(records: FleetVehicle, action: :read, context: user)).to eq([parent])
    expect(access.authorization(subject: van, action: :read, context: user)).not_to be_allowed
  end

  it 'inherits role fields and applies child overrides per action in mixed batches' do
    grant
    grant(action: :update)
    role.update!(accessible_fields: {
      'FleetVehicle' => { 'read' => ['name'], 'update' => ['name', 'description'] },
      'FleetTruck' => { 'update' => [] }
    })
    van = vehicle(FleetVan)
    truck = vehicle(FleetTruck)
    heavy = vehicle(FleetHeavyTruck)
    expect(access.fields_for_many(context: user, action: :read, records: [van, truck, heavy]).values).to eq([['name']] * 3)
    expect(access.fields_for_many(context: user, action: :update, records: [van, truck, heavy]).values).to eq([%w[name description], [], []])
    expect(access.declared_fields(context: user, model: FleetTruck)).to eq(['name'])
  end

  it 'uses explicit all fields and composes inherited field resolvers once' do
    grant
    role.update!(accessible_fields: { 'FleetVehicle' => ['name'], 'FleetTruck' => { 'read' => nil } })
    calls = []
    config.register_field_resolver(model_name: 'FleetVehicle') { |fields:, **| calls << :parent; fields }
    config.register_field_resolver(model_name: 'FleetTruck') { |fields:, **| calls << :child; fields }
    expect(access.readable_fields(context: user, record: vehicle(FleetTruck))).to eq(:all)
    expect(calls).to eq([:parent, :child])
  end

  it 'preserves the explicit shared-model resolver behavior' do
    grant
    boundary(FleetTruck, 'Allowed')
    config.authorization_model_resolver = ->(model) { model.base_class }
    truck = vehicle(FleetTruck, name: 'Other')
    expect(access.authorization(subject: truck, action: :read, context: user)).to be_allowed
  end

  it 'uses only an explicitly selected intermediate model for every decision' do
    grant(model: FleetTruck, action: :update)
    boundary(FleetVehicle, 'Forbidden parent name')
    role.update!(accessible_fields: { 'FleetVehicle' => [], 'FleetTruck' => ['name'] })
    config.register_update_validator(model_name: 'FleetVehicle') { |**| raise 'must not use parent validator' }
    config.authorization_model_resolver = ->(model) { model <= FleetTruck ? FleetTruck : model }
    heavy = vehicle(FleetHeavyTruck)
    truck = vehicle(FleetTruck)
    [heavy, truck].each do |record|
      expect(access.authorization(subject: record, action: :update, context: user)).to be_allowed
      expect(access.validation(subject: record, action: :update, context: user)).to be_allowed
      expect(access.input_fields(record: record, action: :update, context: user)).to eq(['name'])
    end
    expect(access.fields_for_many(records: [heavy, truck], action: :update, context: user).values).to eq([['name'], ['name']])
  end

  it 'retains useful proposed errors when another grant failed its condition' do
    config.register_scope(model_name: 'FleetVehicle', scope_name: 'named',
      validate: ->(record, errors) { errors.add(:name, :not_permitted, message: 'must remain Allowed') unless record.name == 'Allowed' }) { FleetVehicle.where(name: 'Allowed') }
    config.register_condition(name: 'off_duty') { false }
    grant(action: :update, scopes: [:named])
    grant(action: :update, conditions: [:off_duty])
    truck = vehicle(FleetTruck)
    truck.name = 'Rejected'
    result = access.validation(subject: truck, action: :update, context: user)
    expect(result.errors.map(&:attribute)).to eq([:name])
    expect(result.denied_grants.map(&:reason)).to contain_exactly(:condition_failed, :proposed_scope_mismatch)
  end
end
