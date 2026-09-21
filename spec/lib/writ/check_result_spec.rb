require 'rails_helper'

RSpec.describe 'structured authorization results' do
  let(:config) { Writ::Configuration }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions, :organisation_id).new(role.permissions, organisation.id) }
  let(:record) { create(:role, organisation: organisation) }

  around do |example|
    original_registry = config.registry
    original_missing = config.on_missing_condition
    original_error = config.on_condition_error
    original_invalid_arguments = config.on_invalid_condition_arguments
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    example.run
  ensure
    config.instance_variable_set(:@registry, original_registry)
    config.on_missing_condition = original_missing
    config.on_condition_error = original_error
    config.on_invalid_condition_arguments = original_invalid_arguments
  end

  def result_for(action: :read, subject: record)
    Writ::Access.authorization(context: context, action: action, subject: subject)
  end

  it 'keeps saved authorization and local validation entry points separate' do
    draft = Role.new(organisation: organisation)

    expect { result_for(subject: draft) }.to raise_error(ArgumentError, /persisted/)
    expect { Writ::Access.validation(context: context, action: :create, subject: record) }
      .to raise_error(ArgumentError, /new record/)
  end

  it 'returns structured creation results and evaluates conditions once' do
    calls = []
    config.register_condition(name: :closed) { calls << :closed; false }
    permission = create(:permission, role: role, model: 'Role', action: :create, conditions: [:closed])
    create(:permission, role: role, model: 'Role', action: :create)

    result = Writ::Access.validation(context: context, action: :create, subject: Role.new(organisation: organisation))

    expect(result).to be_allowed
    expect(result.reason).to eq(:granted)
    expect(result.denied_grants).to eq([])
    expect(calls).to eq([:closed])
    expect(permission).to be_persisted
  end

  it 'reports creation matcher failures and runs validators only after a grant' do
    config.register_default_scope(model_name: 'Role', matches: ->(_context, value) { value.organisation_id == 0 }) { Role.all }
    permission = create(:permission, role: role, model: 'Role', action: :create)
    validator_calls = 0
    config.register_creation_validator(model_name: 'Role') { |context:, record:| validator_calls += 1; false }

    result = Writ::Access.validation(context: context, action: :create, subject: Role.new(organisation: organisation))
    expect(result).not_to be_allowed
    expect(result.reason).to eq(:proposed_scope_mismatch)
    expect(result.denied_grants).to contain_exactly(
      have_attributes(permission_id: permission.id, reason: :proposed_scope_mismatch)
    )
    expect(validator_calls).to eq(0)
  end

  it 'reports creation validator rejection after a matching grant' do
    create(:permission, role: role, model: 'Role', action: :create)
    calls = 0
    config.register_creation_validator(model_name: 'Role') { |context:, record:| calls += 1; false }

    result = Writ::Access.validation(context: context, action: :create, subject: Role.new(organisation: organisation))

    expect(result.reason).to eq(:validator_rejected)
    expect(calls).to eq(1)
  end

  it 'returns a granted result with no denial details' do
    create(:permission, role: role, model: 'Role', action: :read)

    result = result_for

    expect(result.allowed?).to be(true)
    expect(result.reason).to eq(:granted)
    expect(result.denied_grants).to eq([])
    expect(result.denied_grants).to eq([])
  end

  it 'distinguishes no grants from grants rejected by conditions' do
    no_grants = result_for
    expect(no_grants.allowed?).to be(false)
    expect(no_grants.reason).to eq(:no_grants)

    calls = 0
    config.register_condition(name: :closed) { calls += 1; false }
    permission = create(:permission, role: role, model: 'Role', action: :read, conditions: [:closed])

    result = result_for

    expect(result.allowed?).to be(false)
    expect(result.reason).to eq(:condition_failed)
    expect(result.denied_grants.map(&:permission_id)).to eq([permission.id])
    expect(result.denied_grants.map(&:failed_conditions)).to eq([[:closed]])
    expect(calls).to eq(1)
  end

  it 'distinguishes an absent permission source from an empty source' do
    no_source = Writ::Access.authorization(context: Object.new, action: :read, subject: record)

    expect(no_source).not_to be_allowed
    expect(no_source.reason).to eq(:no_permission_source)
    expect(result_for.reason).to eq(:no_grants)
  end

  it 'returns success without denial details when an alternate grant succeeds' do
    calls = 0
    config.register_condition(name: :closed) { calls += 1; false }
    create(:permission, role: role, model: 'Role', action: :read, conditions: [:closed])
    create(:permission, role: role, model: 'Role', action: :read)

    result = result_for

    expect(result.allowed?).to be(true)
    expect(result.reason).to eq(:granted)
    expect(result.denied_grants).to eq([])
    expect(result.denied_grants).to eq([])
    expect(calls).to eq(1)
  end

  it 'short circuits conditions within a failed grant' do
    calls = []
    config.register_condition(name: :first) { calls << :first; false }
    config.register_condition(name: :later) { calls << :later; raise 'must not run' }
    create(:permission, role: role, model: 'Role', action: :read, conditions: %i[first later])

    result = result_for

    expect(result.allowed?).to be(false)
    expect(result.denied_grants.map(&:failed_conditions)).to eq([[:first]])
    expect(calls).to eq([:first])
  end

  it 'classifies denied condition errors while preserving raise behavior' do
    config.register_condition(name: :broken) { raise 'condition failed' }
    create(:permission, role: role, model: 'Role', action: :read, conditions: [:broken])

    expect { result_for }.to raise_error(RuntimeError, 'condition failed')

    config.on_condition_error = :deny
    result = result_for
    expect(result.allowed?).to be(false)
    expect(result.reason).to eq(:condition_error)
    expect(result.denied_grants.map(&:failed_conditions)).to eq([[:broken]])
  end

  it 'keeps a false condition distinct from an error in deny mode' do
    config.on_condition_error = :deny
    config.register_condition(name: :closed) { false }
    create(:permission, role: role, model: 'Role', action: :read, conditions: [:closed])

    result = result_for

    expect(result.reason).to eq(:condition_failed)
    expect(result.denied_grants.first.reason).to eq(:condition_failed)
  end

  it 'reports and logs a missing condition in deny mode while raise mode still raises' do
    permission = create(:permission, role: role, model: 'Role', action: :read, conditions: [:unregistered_gate])

    expect { result_for }.to raise_error(Writ::ConditionNotFoundError)

    config.on_missing_condition = :deny
    expect(config.logger).to receive(:error).with(/unregistered_gate/)
    result = result_for

    expect(result.reason).to eq(:missing_condition)
    expect(result.denied_grants).to contain_exactly(
      have_attributes(permission_id: permission.id, reason: :missing_condition, failed_conditions: [:unregistered_gate])
    )
  end

  it 'reports invalid condition arguments in deny mode while raise mode still raises' do
    config.register_condition(name: :requires_level, arguments: { level: { type: :string, required: true } }) { |_context, _args| true }
    permission = create(:permission, role: role, model: 'Role', action: :read,
                         conditions: [{ requires_level: { level: 'strict' } }])
    permission.permission_conditions.first.update_column(:arguments, {})

    expect { result_for }.to raise_error(Writ::InvalidArgumentsError)

    config.on_invalid_condition_arguments = :deny
    expect(config.logger).to receive(:error).with(/requires_level/)
    result = result_for

    expect(result.reason).to eq(:condition_arguments_invalid)
    expect(result.denied_grants).to contain_exactly(
      have_attributes(permission_id: permission.id, reason: :condition_arguments_invalid, failed_conditions: [:requires_level])
    )
  end

  it 'reports invalid scope arguments as the overall reason in deny mode' do
    original = config.on_invalid_scope_arguments
    config.register_scope(model_name: 'Role', scope_name: :requires_level,
                          arguments: { level: { type: :string, required: true } }) { |_context, _args| Role.all }
    permission = create(:permission, role: role, model: 'Role', action: :read,
                         scopes: [{ requires_level: { level: 'strict' } }])
    permission.permission_scopes.first.update_column(:arguments, {})
    config.on_invalid_scope_arguments = :deny

    result = result_for

    expect(result.reason).to eq(:scope_arguments_invalid)
    expect(result.denied_grants).to contain_exactly(
      have_attributes(permission_id: permission.id, reason: :scope_arguments_invalid, failed_conditions: [])
    )
  ensure
    config.on_invalid_scope_arguments = original
  end

  it 'reports saved and proposed scope failures separately for updates' do
    config.register_default_scope(model_name: 'Asset', matches: ->(ctx, value) { value.organisation_id == ctx.organisation_id }) do |ctx|
      Asset.where(organisation_id: ctx.organisation_id)
    end
    update_permission = create(:permission, role: role, model: 'Asset', action: :update)
    asset = create(:asset, organisation: organisation)

    saved_result = Writ::Access.authorization(context: context, action: :update, subject: asset)
    expect(saved_result.allowed?).to be(true)
    expect(saved_result.reason).to eq(:granted)

    asset.organisation_id = organisation.id + 1
    proposed_result = Writ::Access.validation(context: context, action: :update, subject: asset)
    expect(proposed_result.allowed?).to be(false)
    expect(proposed_result.reason).to eq(:proposed_scope_mismatch)
    expect(proposed_result.denied_grants.map(&:permission_id)).to eq([update_permission.id])
  end

  it 'reports saved scope mismatch as the top-level update reason' do
    asset = create(:asset, organisation: organisation)
    destination = create(:location)
    config.register_scope(model_name: 'Asset', scope_name: 'locations',
                          matches: ->(_ctx, value) { value.location_id == destination.id }) do |_ctx|
      Asset.where(location_id: destination.id)
    end
    permission = create(:permission, role: role, model: 'Asset', action: :update, scopes: [:locations])

    result = Writ::Access.authorization(context: context, action: :update, subject: asset)

    expect(result).not_to be_allowed
    expect(result.reason).to eq(:scope_mismatch)
    expect(result.denied_grants).to contain_exactly(
      have_attributes(permission_id: permission.id, reason: :scope_mismatch, failed_conditions: [])
    )
  end

  it 'reports validator rejection as a distinct update result' do
    create(:permission, role: role, model: 'Asset', action: :update)
    config.register_update_validator(model_name: 'Asset') { |context:, record:| false }
    asset = create(:asset, organisation: organisation)

    result = Writ::Access.validation(context: context, action: :update, subject: asset)

    expect(result.allowed?).to be(false)
    expect(result.reason).to eq(:validator_rejected)
  end

  it 'does not let a condition-denied proposed grant bypass saved-state authorization' do
    asset = create(:asset, organisation: organisation)
    destination = create(:location)
    calls = []
    config.register_scope(model_name: 'Asset', scope_name: 'locations', arguments: { ids: { type: :array, required: true } },
                          matches: ->(_ctx, value, args) { args[:ids].include?(value.location_id) }) do |_ctx, args|
      Asset.where(location_id: args[:ids])
    end
    config.register_condition(name: :denied_update) { calls << :denied; false }
    config.register_condition(name: :saved_update) { calls << :saved; true }
    create(:permission, role: role, model: 'Asset', action: :update,
           scopes: [{ locations: { ids: [destination.id] } }], conditions: [:denied_update])
    create(:permission, role: role, model: 'Asset', action: :update,
           scopes: [{ locations: { ids: [asset.location_id] } }], conditions: [:saved_update])
    asset.location_id = destination.id

    saved_result = Writ::Access.authorization(context: context, action: :update, subject: asset)
    result = Writ::Access.validation(context: context, action: :update, subject: asset)

    expect(saved_result).to be_allowed
    expect(result.allowed?).to be(false)
    expect(result.reason).to eq(:proposed_scope_mismatch)
    expect(calls).to eq(%i[denied saved denied saved])
  end

  it 'allows different condition-valid grants to cover saved and proposed states' do
    asset = create(:asset, organisation: organisation)
    destination = create(:location)
    config.register_scope(model_name: 'Asset', scope_name: 'locations', arguments: { ids: { type: :array, required: true } },
                          matches: ->(_ctx, value, args) { args[:ids].include?(value.location_id) }) do |_ctx, args|
      Asset.where(location_id: args[:ids])
    end
    config.register_condition(name: :saved_grant) { true }
    config.register_condition(name: :proposed_grant) { true }
    create(:permission, role: role, model: 'Asset', action: :update,
           scopes: [{ locations: { ids: [asset.location_id] } }], conditions: [:saved_grant])
    create(:permission, role: role, model: 'Asset', action: :update,
           scopes: [{ locations: { ids: [destination.id] } }], conditions: [:proposed_grant])
    asset.location_id = destination.id

    saved_result = Writ::Access.authorization(context: context, action: :update, subject: asset)
    result = Writ::Access.validation(context: context, action: :update, subject: asset)

    expect(saved_result).to be_allowed
    expect(result).to be_allowed
    expect(result.reason).to eq(:granted)
  end

  it 'evaluates each condition once for each separate saved and proposed check' do
    asset = create(:asset, organisation: organisation)
    calls = Hash.new(0)
    config.register_condition(name: :first) { calls[:first] += 1; true }
    config.register_condition(name: :second) { calls[:second] += 1; true }
    create(:permission, role: role, model: 'Asset', action: :update, conditions: [:first])
    create(:permission, role: role, model: 'Asset', action: :update, conditions: [:second])

    expect(Writ::Access.authorization(context: context, action: :update, subject: asset)).to be_allowed
    expect(Writ::Access.validation(context: context, action: :update, subject: asset)).to be_allowed
    expect(calls).to eq(first: 2, second: 2)
  end
end
