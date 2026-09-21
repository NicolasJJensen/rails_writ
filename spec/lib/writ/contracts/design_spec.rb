require 'rails_helper'
require 'rake'

RSpec.describe 'Reusable authorization contracts' do
  let(:config) { Writ::Configuration }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions, :roles, :organisation_id).new(role.permissions, Role.where(id: role.id), organisation.id) }
  let!(:asset) { create(:asset, organisation: organisation) }
  before { Current.user = build(:user, organisation: organisation) }
  before { config.register_scope(model_name: 'Asset', scope_name: 'created') { Asset.none } }
  around do |example|
    original_registry = config.registry
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    example.run
  ensure
    config.instance_variable_set(:@registry, original_registry)
    Current.reset
    config.on_missing_matcher = :raise
  end

  it 'distinguishes grant availability from record authorization' do
    create(:permission, role: role, scopes: ['created'])
    expect(Writ::Access.grant_available?(context: context, action: :read, model: Asset)).to be(true)
    expect(Writ::Access.authorization(context: context, action: :read, subject: asset)).not_to be_allowed
  end

  it 'returns separate read and update fields and denies fields without a grant' do
    role.update!(accessible_fields: { 'Asset' => { 'read' => ['name', 'description'], 'update' => ['name'] } })
    create(:permission, role: role)
    create(:permission, role: role, action: :update)
    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq(%w[name description])
    expect(Writ::Access.writable_fields(context: context, record: asset)).to eq(['name'])
    role.permissions.destroy_all
    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq([])
  end

  it 'preloads roles before resolving fields from effective grants' do
    role.update!(accessible_fields: { 'Asset' => ['name'] })
    create(:permission, role: role)
    strict_permissions = role.permissions.strict_loading
    strict_context = Struct.new(:permissions, :roles).new(strict_permissions, Role.where(id: role.id))

    expect(Writ::Access.readable_fields(context: strict_context, record: asset)).to eq(['name'])
  end

  it 'accepts generic nested includes when preparing permissions' do
    permission = create(:permission, role: role)
    prepared = Writ::Access.send(
      :prepare_permissions, context, :read, Asset, includes: { role: :users }
    )

    loaded_permission = prepared.permissions.find { |candidate| candidate.id == permission.id }
    expect(loaded_permission.association(:role)).to be_loaded
    expect(loaded_permission.role.association(:users)).to be_loaded
  end

  it 'excludes field grants whose scopes do not match the record' do
    role.update!(accessible_fields: { 'Asset' => ['description'] })
    create(:permission, role: role, scopes: ['created'])
    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq([])
  end

  it 'allows a consumer to resolve computed field names without serializer dependencies' do
    create(:permission, role: role)
    config.register_field_resolver(model_name: nil) do |context:, action:, record:, fields:|
      record.name.present? ? ['display_name'] : []
    end
    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq(['display_name'])
  ensure
  end

  it 'runs only the model field resolver after effective grant fields are known' do
    role.update!(accessible_fields: { 'Asset' => ['name'] })
    create(:permission, role: role)
    calls = []
    config.register_field_resolver(model_name: 'Asset') do |context:, action:, record:, fields:|
      calls << [action, record.id, fields]
      fields + ['display_name']
    end

    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq(%w[name display_name])
    expect(calls).to eq([[:read, asset.id, ['name']]])
  end

  it 'does not run field resolvers when no grant contributes fields' do
    calls = 0
    config.register_field_resolver(model_name: 'Asset') do |**|
      calls += 1
      ['display_name']
    end

    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq([])
    expect(calls).to eq(0)
  end

  it 'composes the global field resolver before the model resolver only when requested' do
    role.update!(accessible_fields: { 'Asset' => ['name'] })
    create(:permission, role: role)
    calls = []
    config.register_field_resolver(model_name: nil) do |fields:, **|
      calls << :global
      fields + ['global_name']
    end
    config.register_field_resolver(model_name: 'Asset', include_global: true) do |fields:, **|
      calls << :model
      fields + ['model_name']
    end

    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq(%w[name global_name model_name])
    expect(calls).to eq(%i[global model])
  end

  it 'uses the global field resolver only when no model resolver exists' do
    role.update!(accessible_fields: { 'Asset' => ['name'] })
    create(:permission, role: role)
    config.register_field_resolver(model_name: nil) { |fields:, **| fields + ['global_name'] }

    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq(%w[name global_name])
  end

  it 'preserves resolver return values :all and []' do
    role.update!(accessible_fields: { 'Asset' => ['name'] })
    create(:permission, role: role)
    config.register_field_resolver(model_name: 'Asset') { |**| :all }
    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq(:all)

    config.register_field_resolver(model_name: 'Asset', replace: true) { |**| [] }
    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq([])
  end

  it 'passes :all to resolvers and preserves it in the documented safe resolver pattern' do
    role.update!(accessible_fields: { 'Asset' => nil })
    create(:permission, role: role)
    calls = []
    config.register_field_resolver(model_name: 'Asset') do |action:, fields:, **|
      calls << [action, fields]
      fields == :all ? :all : fields + ['display_name']
    end

    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq(:all)
    expect(calls).to eq([[:read, :all]])
  end

  it 'applies appended model field resolvers in declaration order' do
    role.update!(accessible_fields: { 'Asset' => ['name'] })
    create(:permission, role: role)
    calls = []
    config.register_field_resolver(model_name: 'Asset') do |fields:, **|
      calls << [:first, fields]
      fields + ['display_name']
    end
    config.register_field_resolver(model_name: 'Asset', append: true) do |fields:, **|
      calls << [:second, fields]
      fields - ['name']
    end

    expect(Writ::Access.readable_fields(context: context, record: asset)).to eq(['display_name'])
    expect(calls).to eq([[:first, ['name']], [:second, %w[name display_name]]])
  end

  it 'allows an unscoped create grant without an optional validator' do
    create(:permission, role: role, action: :create)
    record = Asset.new(organisation: organisation)
    expect(Writ::Access.validation(context: context, action: :create, subject: record)).to be_allowed
  end

  it 'supports one configurable permission source throughout the public API' do
    create(:permission, role: role)
    config.permission_source = ->(ctx) { ctx.fetch(:grants) }
    ctx = { grants: role.permissions }
    expect(Writ::Access.grant_available?(context: ctx, action: :read, model: Asset)).to be(true)
    expect(Writ::Access.potential_permissions(context: ctx)).to eq('Asset' => { 'read' => true })
  ensure
    config.permission_source = nil
  end

  it 'keeps no-schema scope callbacks on the nil-arguments path' do
    seen = []
    config.register_scope(model_name: 'Asset', scope_name: 'unparameterized') do |_context, *args|
      seen << args
      Asset.all
    end
    create(:permission, role: role, scopes: ['unparameterized'])

    records = Asset.where(id: asset.id)
    expect(Writ::Access.filter(context: context, action: :read, records: records).to_a).to eq([asset])
    expect(seen).to eq([[]])
  end

  it 'does not validate scope arguments after a condition denies the grant' do
    config.register_condition(name: 'denied_before_scope') { false }
    config.register_scope(
      model_name: 'Asset', scope_name: 'invalid_after_denial',
      arguments: { required_id: { type: :integer, required: true } }
    ) { |_context, _args| Asset.all }
    permission = create(:permission, role: role, conditions: ['denied_before_scope'],
                        scopes: [{ invalid_after_denial: { required_id: 1 } }])
    permission.permission_scopes.first.update_column(:arguments, {})

    expect(Writ::Access.filter(context: context, action: :read, records: Asset)).to be_empty
  end

  it 'does not reuse normalized scope arguments between evaluations of one attachment' do
    first_location = asset.location
    second_location = create(:location)
    config.register_scope(
      model_name: 'Asset', scope_name: 'locations',
      arguments: { ids: { type: :array, required: true } }
    ) { |_context, args| Asset.where(location_id: args[:ids]) }
    permission = create(:permission, role: role, scopes: [{ locations: { ids: [first_location.id] } }])
    permission = Permission.includes(permission_scopes: :scope).find(permission.id)
    attachment = permission.permission_scopes.first

    expect(Writ::Access::ScopeEvaluator.scope_arguments_valid?(permission)).to be(true)
    expect(Writ::Access::ScopeEvaluator.filter_records_by_context_and_permission(
      context, Asset, permission
    ).pluck(:id)).to eq([asset.id])

    attachment.arguments = { 'ids' => [second_location.id] }
    expect(Writ::Access::ScopeEvaluator.filter_records_by_context_and_permission(
      context, Asset, permission
    ).to_a).to be_empty
  end

  it 'uses proposed scope matchers for create and optional validators as an additional check' do
    config.register_scope(
      model_name: 'Asset', scope_name: 'organisation',
      matches: ->(_context, record) { record.organisation_id == organisation.id }
    ) { |ctx| Asset.where(organisation_id: ctx.organisation_id) }
    create(:permission, role: role, action: :create, scopes: ['organisation'])

    valid = Asset.new(organisation: organisation)
    invalid = Asset.new(organisation_id: organisation.id + 1)
    expect(Writ::Access.validation(context: context, action: :create, subject: valid)).to be_allowed
    expect(Writ::Access.validation(context: context, action: :create, subject: invalid)).not_to be_allowed

    calls = 0
    config.register_creation_validator(model_name: nil) do |context:, record:|
      calls += 1
      record.name.present?
    end
    valid.name = 'New asset'
    expect(Writ::Access.validation(context: context, action: :create, subject: valid)).to be_allowed
    expect(calls).to eq(1)
  end

  it 'applies the default proposed matcher to an unscoped create grant' do
    config.register_default_scope(
      model_name: 'Asset',
      matches: ->(ctx, record) { record.organisation_id == ctx.organisation_id }
    ) { |ctx| Asset.where(organisation_id: ctx.organisation_id) }
    create(:permission, role: role, action: :create)

    expect(Writ::Access.validation(context: context, action: :create,
                                                subject: Asset.new(organisation_id: organisation.id))).to be_allowed
    expect(Writ::Access.validation(context: context, action: :create,
                                                subject: Asset.new(organisation_id: organisation.id + 1))).not_to be_allowed
  end

  it 'ANDs scopes within one create grant and ORs separate grants' do
    config.register_scope(model_name: 'Asset', scope_name: 'same_organisation',
                          matches: ->(ctx, record) { record.organisation_id == ctx.organisation_id }) do |ctx|
      Asset.where(organisation_id: ctx.organisation_id)
    end
    config.register_scope(model_name: 'Asset', scope_name: 'named',
                          matches: ->(_ctx, record) { record.name == 'allowed' }) { Asset.where(name: 'allowed') }
    create(:permission, role: role, action: :create, scopes: %w[same_organisation named])

    expect(Writ::Access.validation(context: context, action: :create,
                                                subject: Asset.new(organisation_id: organisation.id, name: 'allowed'))).to be_allowed
    expect(Writ::Access.validation(context: context, action: :create,
                                                subject: Asset.new(organisation_id: organisation.id, name: 'denied'))).not_to be_allowed

    role.permissions.destroy_all
    create(:permission, role: role, action: :create, scopes: ['same_organisation'])
    create(:permission, role: role, action: :create, scopes: ['named'])
    expect(Writ::Access.validation(context: context, action: :create,
                                                subject: Asset.new(organisation_id: organisation.id, name: 'denied'))).to be_allowed
  end

  it 'keeps missing proposed matchers explicit and supports skipping only that matcher' do
    config.register_scope(model_name: 'Asset', scope_name: 'organisation') { |ctx| Asset.where(organisation_id: ctx.organisation_id) }
    create(:permission, role: role, action: :create, scopes: ['organisation'])
    record = Asset.new(organisation: organisation)

    expect {
      Writ::Access.validation(context: context, action: :create, subject: record)
    }.to raise_error(Writ::ConfigurationError, /matcher/)

    config.on_missing_matcher = :skip
    expect(Writ::Access.validation(context: context, action: :create, subject: record)).to be_allowed
  ensure
    config.on_missing_matcher = :raise
  end

  it 'still evaluates existing matchers when missing matchers are skipped' do
    calls = []
    config.register_scope(model_name: 'Asset', scope_name: 'missing') { Asset.all }
    config.register_scope(model_name: 'Asset', scope_name: 'reject',
                          matches: ->(_ctx, _record) { calls << :reject; false }) { Asset.all }
    create(:permission, role: role, action: :create, scopes: %w[missing reject])
    config.on_missing_matcher = :skip

    expect(Writ::Access.validation(context: context, action: :create, subject: Asset.new)).not_to be_allowed
    expect(calls).to eq([:reject])
  ensure
    config.on_missing_matcher = :raise
  end

  it 'propagates an existing matcher exception when missing matchers are skipped' do
    config.register_scope(model_name: 'Asset', scope_name: 'missing') { Asset.all }
    config.register_scope(model_name: 'Asset', scope_name: 'broken',
                          matches: ->(_ctx, _record) { raise 'matcher failed' }) { Asset.all }
    create(:permission, role: role, action: :create, scopes: %w[missing broken])
    config.on_missing_matcher = :skip

    expect {
      Writ::Access.validation(context: context, action: :create, subject: Asset.new)
    }.to raise_error(RuntimeError, 'matcher failed')
  ensure
    config.on_missing_matcher = :raise
  end

  it 'runs global and model creation validators in order without short-circuiting' do
    create(:permission, role: role, action: :create)
    calls = []
    config.register_creation_validator(model_name: nil) do |context:, record:|
      calls << :global
      false
    end
    config.register_creation_validator(model_name: 'Asset') do |context:, record:|
      calls << :model
      true
    end

    expect(Writ::Access.validation(context: context, action: :create, subject: Asset.new)).not_to be_allowed
    expect(calls).to eq(%i[global model])
  end

  it 'propagates validator exceptions and does not invoke validators after failed base authorization' do
    create(:permission, role: role, action: :create)
    config.register_creation_validator(model_name: nil) { |context:, record:| raise 'validator failed' }
    expect {
      Writ::Access.validation(context: context, action: :create, subject: Asset.new)
    }.to raise_error(RuntimeError, 'validator failed')

    role.permissions.destroy_all
    calls = 0
    config.register_creation_validator(model_name: nil) do |context:, record:|
      calls += 1
      true
    end
    expect(Writ::Access.validation(context: context, action: :create, subject: Asset.new)).not_to be_allowed
    expect(calls).to eq(0)
  end

  it 'preflights missing matchers across every eligible create grant before OR short-circuiting' do
    config.register_scope(model_name: 'Asset', scope_name: 'valid', matches: ->(_ctx, _record) { true }) { Asset.all }
    config.register_scope(model_name: 'Asset', scope_name: 'missing') { Asset.all }
    create(:permission, role: role, action: :create, scopes: ['valid'])
    create(:permission, role: role, action: :create, scopes: ['missing'])

    expect {
      Writ::Access.validation(context: context, action: :create, subject: Asset.new)
    }.to raise_error(Writ::ConfigurationError, /missing|matcher/)
  end

  it 'preflights missing matchers for create fields before resolving fields' do
    role.update!(accessible_fields: { 'Asset' => { 'create' => ['name'] } })
    config.register_scope(model_name: 'Asset', scope_name: 'missing_fields') { Asset.all }
    create(:permission, role: role, action: :create, scopes: ['missing_fields'])

    expect {
      Writ::Access.fields_for(context: context, action: :create, record: Asset.new)
    }.to raise_error(Writ::ConfigurationError, /matcher/)
  end

  it 'uses the same proposed grant eligibility for create fields as create authorization' do
    allowed_role = role
    denied_role = create(:role, organisation: organisation, name: 'Denied')
    allowed_role.update!(accessible_fields: { 'Asset' => { 'create' => ['name'] } })
    denied_role.update!(accessible_fields: { 'Asset' => { 'create' => ['secret'] } })
    user = create(:user, organisation: organisation)
    user.roles << [allowed_role, denied_role]
    field_context = Struct.new(:permissions, :roles).new(
      Permission.where(role_id: [allowed_role.id, denied_role.id]),
      Role.where(id: [allowed_role.id, denied_role.id])
    )
    config.register_scope(
      model_name: 'Asset', scope_name: 'organisation',
      matches: ->(_context, record) { record.organisation_id == organisation.id }
    ) { |ctx| Asset.where(organisation_id: ctx.organisation_id) }
    create(:permission, role: allowed_role, action: :create)
    create(:permission, role: denied_role, action: :create, scopes: ['organisation'])
    candidate = Asset.new(organisation_id: organisation.id + 1)

    expect(Writ::Access.fields_for(context: field_context, action: :create, record: candidate)).to eq(['name'])
  end

  it 'emits filter denial events without loading returned records' do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe('permission.filter.writ') { |*args| events << args.last }
    result = Writ::Access.filter(context: nil, action: :read, records: Asset)
    expect(result).not_to be_loaded
    expect(events.last).to include(reason: 'no_permission_source', timing: 'query_construction', permissions_count: 0)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'does not construct argument telemetry without a subscriber' do
    create(:permission, role: role)
    expect(Writ::Access).not_to receive(:collect_arguments_applied)
    Writ::Access.filter(context: context, action: :read, records: Asset)
  end

  it 'preserves the last usable registry after a failed rebuild' do
    config.register_default_scope(model_name: 'Asset') { Asset.all }
    original = config.registry
    expect { config.rebuild! { raise 'registration failed' } }.to raise_error('registration failed')
    expect(config.registry).to equal(original)
    expect(config.registry.get_default_scope(model_name: 'Asset')).to be_present
  end

  it 'replays consumer configure blocks into rebuilt registries' do
    original = config.registry
    original_blocks = config.instance_variable_get(:@configure_blocks)&.dup
    config.configure { condition(:contract_replayed) { true } }
    config.rebuild! {}
    expect(config.registry.condition_registered?(name: 'contract_replayed')).to be(true)
  ensure
    config.instance_variable_set(:@registry, original)
    config.instance_variable_set(:@configure_blocks, original_blocks)
  end

  it 'does not remove catalog restrictions still referenced by a custom grant during cleanup' do
    config.registry.register_condition(name: 'obsolete_contract') { false }
    permission = create(:permission, role: role, conditions: ['obsolete_contract'])
    config.registry.remove_condition(name: 'obsolete_contract')
    load File.expand_path('../../../../lib/tasks/writ.rake', __dir__) unless Rake::Task.task_defined?('writ:cleanup')
    Rake::Task.define_task(:environment)
    old_confirm = ENV['CONFIRM']
    ENV['CONFIRM'] = '1'
    Rake::Task['writ:cleanup'].reenable
    Rake::Task['writ:cleanup'].invoke
    expect(permission.reload.conditions).to eq(['obsolete_contract'])
  ensure
    ENV['CONFIRM'] = old_confirm
  end
end
