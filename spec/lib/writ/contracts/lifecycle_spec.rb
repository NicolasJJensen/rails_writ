require 'rails_helper'

RSpec.describe 'Lifecycle and observability contracts' do
  let(:config) { Writ::Configuration }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions).new(role.permissions) }
  before { Current.user = build(:user, organisation: organisation) }
  after { Current.reset }

  it 'keeps published definitions visible to other threads during rebuilding' do
    previous = config.registry
    during = nil
    config.rebuild! do
      during = Thread.new { config.registry }.value
      config.register_condition(name: 'candidate') { true }
    end
    expect(during).to equal(previous)
    expect(config.registry.condition_registered?(name: 'candidate')).to be(true)
  ensure
    config.instance_variable_set(:@registry, previous)
  end

  it 'preserves policies across repeated prepare callbacks without an unload' do
    before = config.registry.all_permissions
    Rails.application.reloader.prepare!
    Rails.application.reloader.prepare!
    expect(config.registry.all_permissions).to eq(before)
    expect(before).not_to be_empty
  end

  it 'keeps custom loggers across rebuilding' do
    original_logger = config.logger
    original_registry = config.registry
    logger = Logger.new(StringIO.new)
    config.logger = logger
    config.rebuild! {}
    expect(config.logger).to equal(logger)
  ensure
    config.logger = original_logger
    config.instance_variable_set(:@registry, original_registry)
  end

  it 'reports only conditions actually visited before a denial' do
    config.register_condition(name: 'first_denial') { false }
    config.register_condition(name: 'never_called') { raise 'must short circuit' }
    create(:permission, role: role, conditions: %w[first_denial never_called])
    events = []
    subscriber = ActiveSupport::Notifications.subscribe('permission.filter.writ') { |*args| events << args.last }
    Writ::Access.filter(context: context, action: :read, records: Asset)
    expect(events.last).to include(reason: 'no_valid_grants', conditions_evaluated: ['first_denial'])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    config.remove_condition(name: 'first_denial')
    config.remove_condition(name: 'never_called')
  end

  it 'reports construction errors and still propagates them' do
    config.register_condition(name: 'crash_contract') { raise 'private detail' }
    create(:permission, role: role, conditions: ['crash_contract'])
    events = []
    subscriber = ActiveSupport::Notifications.subscribe('permission.filter.writ') { |*args| events << args.last }
    expect { Writ::Access.filter(context: context, action: :read, records: Asset) }.to raise_error('private detail')
    expect(events.last).to include(reason: 'error', error_class: 'RuntimeError')
    expect(events.last.to_s).not_to include('private detail')
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    config.remove_condition(name: 'crash_contract')
  end

  it 'passes arguments to a registered splat condition' do
    config.register_condition(name: 'splat_contract', arguments: { allow: { type: :boolean, required: true } }) { |*args| args.last.fetch(:allow) }
    create(:permission, role: role, conditions: [{ splat_contract: { allow: true } }])
    expect(Writ::Access.grant_available?(context: context, action: :read, model: Asset)).to be(true)
  ensure
    config.remove_condition(name: 'splat_contract')
  end

  it 'supports strict default fields and explicit unrestricted grants' do
    original = config.field_default
    config.field_default = []
    create(:permission, role: role)
    record = create(:asset, organisation: organisation)
    expect(Writ::Access.readable_fields(context: context, record: record)).to eq([])
    role.update!(accessible_fields: { 'Asset' => nil })
    role.reload
    expect(Writ::Access.readable_fields(context: context, record: record)).to eq(:all)
  ensure
    config.field_default = original
  end

  it 'persists only selected action fields through permission migration' do
    original = config.registry
    config.rebuild! do
      Writ.configure do
        permission :read, model: Asset, role: 'Field Role'
        accessible_fields [:name], model: Asset, role: 'Field Role', action: :read
        accessible_fields [], model: Asset, role: 'Field Role', action: :update
      end
    end
    Writ::Generator.add_permissions(organisation, permissions: [{ model: 'Asset', action: :read }])
    expect(organisation.roles.find_by!(name: 'Field Role').accessible_fields).to eq('Asset' => { 'read' => ['name'] })
  ensure
    config.instance_variable_set(:@registry, original)
  end

  it 'keeps Pundit create checks separate from proposed-record validation' do
    original_registry = config.registry
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    proposed = Asset.new(organisation: organisation)

    expect(AssetPolicy.new(context, proposed).create?).to be(false)

    config.register_condition(name: 'pundit_create_gate') { false }
    create(:permission, role: role, action: :create, conditions: ['pundit_create_gate'])
    expect(AssetPolicy.new(context, proposed).create?).to be(false)

    role.permissions.destroy_all
    create(:permission, role: role, action: :create)
    validator_calls = 0
    config.register_creation_validator(model_name: 'Asset') do |context:, record:|
      validator_calls += 1
      false
    end
    expect(AssetPolicy.new(context, proposed).create?).to be(true)
    expect(Writ::Access.validation(context: context, action: :create, subject: proposed)).not_to be_allowed
    expect(validator_calls).to eq(1)
  ensure
    config.instance_variable_set(:@registry, original_registry) if original_registry
  end
end
