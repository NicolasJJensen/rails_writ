require 'rails_helper'

RSpec.describe 'Batch field decisions' do
  let(:config) { Writ::Configuration }
  let(:access) { Writ::Access }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation, accessible_fields: { 'Asset' => { 'read' => ['name'] } }) }
  let(:context) { Struct.new(:permissions).new(role.permissions) }

  before { Current.user = build(:user, organisation: organisation) }
  after do
    config.remove_scope_callable(model_name: 'Asset', scope_name: 'batch_selected')
    config.remove_condition(name: 'batch_denied')
    config.registry.instance_variable_get(:@field_resolvers)&.clear
    Current.reset
  end

  it 'returns record-specific fields and empty fields for denied records without per-record membership queries' do
    records = create_list(:asset, 4, organisation: organisation)
    permitted_ids = records.take(2).map(&:id)
    config.register_scope(model_name: 'Asset', scope_name: 'batch_selected') { Asset.where(id: permitted_ids) }
    3.times { create(:permission, role: role, scopes: ['batch_selected']) }
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      payload = args.last
      queries << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    result = ActiveRecord::Base.uncached { access.fields_for_many(context: context, action: :read, records: records) }
    expect(result).to eq(records.to_h { |record| [record, permitted_ids.include?(record.id) ? ['name'] : []] })
    membership_queries = queries.grep(/FROM "assets"/)
    expect(membership_queries.length).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'groups single-record field membership by role' do
    record = create(:asset, organisation: organisation)
    3.times { create(:permission, role: role) }
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      payload = args.last
      queries << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end

    result = ActiveRecord::Base.uncached do
      access.fields_for(context: context, action: :read, record: record)
    end

    expect(result).to eq(['name'])
    expect(queries.grep(/FROM "assets"/).length).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'keeps single-record fields equivalent to the batch decision for denied grants and resolvers' do
    records = create_list(:asset, 2, organisation: organisation)
    config.register_scope(model_name: 'Asset', scope_name: 'batch_selected') { Asset.where(id: records.first.id) }
    config.register_condition(name: 'batch_denied') { false }
    create(:permission, role: role, scopes: ['batch_selected'])
    denied_role = create(:role, organisation: organisation, accessible_fields: { 'Asset' => ['secret'] })
    create(:permission, role: denied_role, conditions: ['batch_denied'])
    field_context = Struct.new(:permissions).new(Permission.where(role: [role, denied_role]))
    config.register_field_resolver(model_name: nil) do |context:, action:, record:, fields:|
      fields + ['computed']
    end

    batch = access.fields_for_many(context: field_context, action: :read, records: records)
    single = records.to_h do |record|
      [record, access.fields_for(context: field_context, action: :read, record: record)]
    end

    expect(single).to eq(batch)
    expect(single[records.first]).to eq(['name', 'computed'])
    expect(single[records.last]).to eq([])
  end

  it 'combines only effective roles and calls the resolver only for authorized records' do
    records = create_list(:asset, 2, organisation: organisation)
    selected_id = records.first.id
    config.register_scope(model_name: 'Asset', scope_name: 'batch_selected') { Asset.where(id: selected_id) }
    config.register_condition(name: 'batch_denied') { false }
    create(:permission, role: role, scopes: ['batch_selected'])
    denied_role = create(:role, organisation: organisation, accessible_fields: { 'Asset' => nil })
    create(:permission, role: denied_role, conditions: ['batch_denied'])
    all_context = Struct.new(:permissions).new(Permission.where(role: [role, denied_role]))
    calls = []
    config.register_field_resolver(model_name: nil) do |context:, action:, record:, fields:|
      calls << record.id
      fields + ['computed']
    end
    expect(access.fields_for_many(context: all_context, action: :read, records: records))
      .to eq(records.first => ['name', 'computed'], records.last => [])
    expect(calls).to eq([selected_id])
  end

  it 'isolates resolver input fields between records in a batch' do
    records = create_list(:asset, 2, organisation: organisation)
    create(:permission, role: role)
    config.register_field_resolver(model_name: nil) do |context:, action:, record:, fields:|
      fields.first << record.id.to_s
      fields
    end
    expect(access.fields_for_many(context: context, action: :read, records: records))
      .to eq(records.to_h { |record| [record, ["name#{record.id}"]] })
  end

  it 'observes changed grants between batch calls rather than caching results globally' do
    record = create(:asset, organisation: organisation)
    permission = create(:permission, role: role)
    expect(access.fields_for_many(context: context, action: :read, records: [record])[record]).to eq(['name'])
    permission.destroy!
    expect(access.fields_for_many(context: context, action: :read, records: [record])[record]).to eq([])
  end

  it 'does not expose fields for a persisted record outside the default scope' do
    record = create(:asset, organisation: organisation)
    create(:permission, role: role)
    config.register_default_scope(model_name: 'Asset', replace: true) { Asset.none }

    expect(access.fields_for(context: context, action: :read, record: record)).to eq([])
  ensure
    config.registry.remove_default_scope(model_name: 'Asset')
  end

  it 'accepts an empty batch and rejects unsaved or mixed-model batches clearly' do
    expect(access.fields_for_many(context: context, action: :read, records: [])).to eq({})
    expect { access.fields_for_many(context: context, action: :read, records: [Asset.new]) }.to raise_error(ArgumentError, /persisted/i)
    expect { access.fields_for_many(context: context, action: :read, records: [create(:asset), organisation]) }.to raise_error(ArgumentError, /same model/i)
  end
end
