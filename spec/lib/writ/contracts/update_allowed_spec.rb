require 'rails_helper'

RSpec.describe 'Update authorization for proposed attributes' do
  let(:config) { Writ::Configuration }
  let(:access) { Writ::Access }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions, :organisation_id).new(role.permissions, organisation.id) }
  let(:asset) { create(:asset, organisation: organisation) }

  around do |example|
    original = config.registry
    organisation
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    example.run
  ensure
    config.instance_variable_set(:@registry, original)
    Current.reset
  end

  def register_rules
    config.register_default_scope(model_name: 'Asset', matches: ->(ctx, record) { record.organisation_id == ctx.organisation_id }) do |ctx|
      Asset.where(organisation_id: ctx.organisation_id)
    end
    config.register_scope(model_name: 'Asset', scope_name: 'locations', arguments: { ids: { type: :array, required: true } },
                          matches: ->(_ctx, record, args) { args[:ids].include?(record.location_id) }) do |_ctx, args|
      Asset.where(location_id: args[:ids])
    end
  end

  def grant(ids)
    create(:permission, role: role, action: :update, scopes: [{ locations: { ids: ids } }])
  end

  def saved_result(record)
    access.authorization(context: context, action: :update, subject: record)
  end

  def proposed_result(record)
    access.validation(context: context, action: :update, subject: record)
  end

  it 'allows both permitted states without saving or clearing pending changes' do
    register_rules
    destination = create(:location)
    grant([asset.location_id, destination.id])
    original_id = asset.location_id
    asset.location_id = destination.id
    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(true)
    expect(asset.location_id).to eq(destination.id)
    expect(asset).to be_changed
    expect(Asset.find(asset.id).location_id).to eq(original_id)
  end

  it 'denies a proposed destination outside the grants' do
    register_rules
    grant([asset.location_id])
    asset.location_id = create(:location).id
    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(false)
  end

  it 'denies moving an unauthorized saved record into an authorized location' do
    register_rules
    destination = create(:location)
    grant([destination.id])
    asset.location_id = destination.id
    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(false)
  end

  it 'allows different grants to authorize the saved and proposed states' do
    register_rules
    destination = create(:location)
    grant([asset.location_id])
    grant([destination.id])
    asset.location_id = destination.id
    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(true)
  end

  it 'enforces the proposed tenant boundary for unrestricted grants' do
    register_rules
    create(:permission, role: role, action: :update)
    asset.organisation_id = organisation.id + 1
    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(false)
  end

  it 'requires matchers for attached scopes and the default scope' do
    config.register_default_scope(model_name: 'Asset', replace: true) { Asset.all }
    create(:permission, role: role, action: :update)
    expect { [saved_result(asset), proposed_result(asset)].all?(&:allowed?) }.to raise_error(Writ::ConfigurationError, /matcher/)
    config.register_default_scope(model_name: 'Asset', matches: ->(_ctx, _record) { true }, replace: true) { Asset.all }
    config.register_scope(model_name: 'Asset', scope_name: 'missing') { Asset.all }
    role.permissions.destroy_all
    create(:permission, role: role, action: :update, scopes: ['missing'])
    expect { [saved_result(asset), proposed_result(asset)].all?(&:allowed?) }.to raise_error(Writ::ConfigurationError, /matcher/)
  end

  it 'evaluates conditions once for each saved and proposed check' do
    register_rules
    calls = 0
    config.register_condition(name: 'gate') { calls += 1; false }
    create(:permission, role: role, action: :update, conditions: ['gate'])
    expect(saved_result(asset)).not_to be_allowed
    expect(proposed_result(asset)).not_to be_allowed
    expect(calls).to eq(2)
  end

  it 'rejects new records and primary key changes' do
    expect { [saved_result(Asset.new), proposed_result(Asset.new)].all?(&:allowed?) }.to raise_error(ArgumentError)
    saved = asset
    saved.id = saved.id + 1
    expect { [saved_result(saved), proposed_result(saved)].all?(&:allowed?) }.to raise_error(ArgumentError, /primary key/)
  end

  it 'ANDs proposed scopes and does not let a condition-denied grant authorize the destination' do
    register_rules
    config.register_scope(model_name: 'Asset', scope_name: 'active', matches: ->(_ctx, record) { record.status == 'satisfactory' }) { Asset.where(status: :satisfactory) }
    config.register_condition(name: 'denied') { false }
    create(:permission, role: role, action: :update, scopes: [{ locations: { ids: [asset.location_id] } }, 'active'])
    create(:permission, role: role, action: :update, conditions: ['denied'])
    asset.status = :maintenance_required
    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(false)
  end

  it 'keeps ordinary persisted checks available without matchers' do
    config.register_default_scope(model_name: 'Asset') { Asset.all }
    create(:permission, role: role, action: :update)
    asset.location_id = create(:location).id
    expect(saved_result(asset).allowed?).to be(true)
  end

  it 'runs global and model update validators in order without short-circuiting' do
    create(:permission, role: role, action: :update)
    calls = []
    config.register_update_validator(model_name: nil) do |context:, record:|
      calls << :global
      false
    end
    config.register_update_validator(model_name: 'Asset') do |context:, record:|
      calls << :model
      true
    end

    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(false)
    expect(calls).to eq(%i[global model])
  end

  it 'keeps saved-state membership required when proposed matchers are skipped' do
    config.register_default_scope(model_name: 'Asset', matches: ->(ctx, record) { record.organisation_id == ctx.organisation_id }) do |ctx|
      Asset.where(organisation_id: ctx.organisation_id)
    end
    create(:permission, role: role, action: :update)
    config.on_missing_matcher = :skip
    other = create(:organisation)
    proposed = asset
    proposed.organisation_id = other.id

    expect([saved_result(proposed), proposed_result(proposed)].all?(&:allowed?)).to be(false)
  ensure
    config.on_missing_matcher = :raise
  end

  it 'propagates update validator exceptions and does not invoke validators after failed base authorization' do
    create(:permission, role: role, action: :update)
    config.register_update_validator(model_name: nil) { |context:, record:| raise 'validator failed' }
    expect { [saved_result(asset), proposed_result(asset)].all?(&:allowed?) }.to raise_error(RuntimeError, 'validator failed')

    role.permissions.destroy_all
    calls = 0
    config.register_update_validator(model_name: nil) do |context:, record:|
      calls += 1
      true
    end
    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(false)
    expect(calls).to eq(0)
  end

  it 'rejects pending nested records instead of ignoring their changes' do
    register_rules
    grant([asset.location_id])
    asset.service_industries.build(name: 'Proposed industry')
    expect { [saved_result(asset), proposed_result(asset)].all?(&:allowed?) }.to raise_error(ArgumentError, /association/)
  end

  it 'propagates matcher errors rather than granting access' do
    config.register_default_scope(model_name: 'Asset', matches: ->(_ctx, _record) { raise 'matcher failed' }) { Asset.all }
    create(:permission, role: role, action: :update)
    expect { [saved_result(asset), proposed_result(asset)].all?(&:allowed?) }.to raise_error(RuntimeError, 'matcher failed')
  end

  it 'leaves freshness of unchanged attributes to the host' do
    config.register_scope(model_name: 'Asset', scope_name: 'allowed_state',
                          matches: ->(_ctx, record) { (record.description == 'A' && record.status == 'satisfactory') || (record.description == 'B' && record.status == 'maintenance_required') }) do
      Asset.where(description: 'A', status: :satisfactory).or(Asset.where(description: 'B', status: :maintenance_required))
    end
    create(:permission, role: role, action: :update, scopes: ['allowed_state'])
    asset.update!(description: 'A', status: :maintenance_required)
    Asset.find(asset.id).update!(description: 'B')
    asset.status = :satisfactory
    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(true)
    expect(asset.description).to eq('A')
    expect(asset.status).to eq('satisfactory')
  end

  it 'passes the supplied instance to default and parameterized matchers' do
    seen = []
    config.register_default_scope(model_name: 'Asset', matches: ->(_ctx, proposed) { seen << proposed; true }) { Asset.all }
    config.register_scope(model_name: 'Asset', scope_name: 'locations', arguments: { ids: { type: :array, required: true } },
                          matches: ->(_ctx, proposed, args) { seen << proposed; args[:ids].include?(proposed.location_id) }) do |_ctx, args|
      Asset.where(location_id: args[:ids])
    end
    grant([asset.location_id])
    asset.description = 'Pending description'
    changes = asset.changes_to_save.deep_dup
    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(true)
    expect(seen.length).to eq(2)
    expect(seen).to all(equal(asset))
    expect(asset.changes_to_save).to eq(changes)
  end

  it 'isolates matcher arguments from mutations made by the saved-state scope callback' do
    config.register_scope(
      model_name: 'Asset', scope_name: 'locations',
      arguments: { ids: { type: :array, required: true } },
      matches: ->(_ctx, proposed, args) { args[:ids].include?(proposed.location_id) }
    ) do |_ctx, args|
      ids = args[:ids]
      query = Asset.where(location_id: ids)
      ids.clear
      ids << -1
      query
    end
    grant([asset.location_id])

    expect([saved_result(asset), proposed_result(asset)].all?(&:allowed?)).to be(true)
  end

  it 'does not authorize a value produced by invoking a custom setter twice' do
    stub_const('SetterAsset', Class.new(ActiveRecord::Base) do
      self.table_name = 'assets'
      def description=(value)
        super("#{value}!")
      end
    end)
    asset.update!(description: 'saved')
    proposed = SetterAsset.find(asset.id)
    config.register_scope(model_name: 'SetterAsset', scope_name: 'allowed_value',
                          matches: ->(_ctx, record) { %w[saved forbidden!!].include?(record.description) }) do
      SetterAsset.where(description: %w[saved forbidden!!])
    end
    create(:permission, role: role, model: 'SetterAsset', action: :update, scopes: ['allowed_value'])
    proposed.description = 'forbidden'
    expect(proposed.description).to eq('forbidden!')
    expect([saved_result(proposed), proposed_result(proposed)].all?(&:allowed?)).to be(false)
    expect(proposed.description).to eq('forbidden!')
    expect(asset.reload.description).to eq('saved')
  end

  it 'evaluates in-place changes to a JSON attribute without altering them' do
    stub_const('JsonAsset', Class.new(ActiveRecord::Base) do
      self.table_name = 'assets'
      attribute :description, ActiveRecord::Type::Json.new
    end)
    proposed = JsonAsset.find(asset.id)
    proposed.update!(description: { 'allowed' => true })
    config.register_scope(model_name: 'JsonAsset', scope_name: 'allowed_value',
                          matches: ->(_ctx, record) { record.description['allowed'] }) do
      JsonAsset.where(description: { 'allowed' => true })
    end
    create(:permission, role: role, model: 'JsonAsset', action: :update, scopes: ['allowed_value'])
    proposed.description['allowed'] = false
    expect([saved_result(proposed), proposed_result(proposed)].all?(&:allowed?)).to be(false)
    expect(proposed.description).to eq('allowed' => false)
    expect(proposed.changes_to_save).to have_key('description')
    expect(JsonAsset.find(asset.id).description).to eq('allowed' => true)
  end

  it 'returns separate saved and proposed update decisions' do
    register_rules
    grant([asset.location_id])
    expect(saved_result(asset)).to be_allowed
    expect(proposed_result(asset)).to be_allowed
  end

  it 'removes old matchers when a rule is replaced or removed' do
    register_rules
    config.register_scope(model_name: 'Asset', scope_name: 'locations', replace: true) { Asset.all }
    expect(config.registry.get_scope_matcher(model_name: 'Asset', scope_name: 'locations')).to be_nil
    config.registry.remove_default_scope(model_name: 'Asset')
    expect(config.registry.get_default_scope_matcher(model_name: 'Asset')).to be_nil
  end
end

RSpec.describe 'Update matcher definition contracts' do
  let(:config) { Writ::Configuration }

  around do |example|
    original = config.registry
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    example.run
  ensure
    config.instance_variable_set(:@registry, original)
  end

  it 'registers matchers through the policy DSL' do
    stub_const('UpdateDslAssetPolicy', Class.new do
      include Writ::Pundit::PolicyHelpers
      def self.policy_model
        Asset
      end
    end)
    default = ->(_ctx, record) { !record.archived }
    scoped = ->(_ctx, record, args) { args[:statuses].include?(record.status) }
    UpdateDslAssetPolicy.default_scope(matches: default) { Asset.where(archived: false) }
    UpdateDslAssetPolicy.scope(:status, arguments: { statuses: { type: :array } }, matches: scoped) { |_ctx, args| Asset.where(status: args[:statuses]) }
    expect(config.registry.get_default_scope_matcher(model_name: 'Asset')).to eq(default)
    expect(config.registry.get_scope_matcher(model_name: 'Asset', scope_name: 'status')).to eq(scoped)
  end

  it 'validates matcher signatures at registration' do
    expect { config.register_default_scope(model_name: 'Asset', matches: ->(_ctx) { true }) { Asset.all } }.to raise_error(ArgumentError)
    expect { config.register_scope(model_name: 'Asset', scope_name: 'bad', arguments: { ids: { type: :array } }, matches: ->(_ctx, _record) { true }) { |_ctx, _args| Asset.all } }.to raise_error(ArgumentError)
  end

  it 'clears matchers when rebuilding the registry' do
    config.register_default_scope(model_name: 'Asset', matches: ->(_ctx, _record) { true }) { Asset.all }
    config.registry.clear!
    expect(config.registry.get_default_scope_matcher(model_name: 'Asset')).to be_nil
  end
end
