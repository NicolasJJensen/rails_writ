require 'rails_helper'

RSpec.describe 'scope query and proposed validation declarations' do
  let(:config) { Writ::Configuration }
  let(:dsl) { Writ::DSL::ConfigurationDSL.new(config) }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions, :organisation_id).new(role.permissions, organisation.id) }
  let(:record) { Role.new(name: 'Published', organisation: organisation) }

  around do |example|
    original = config.registry
    original_missing = config.on_missing_matcher
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    config.on_missing_matcher = :raise
    example.run
  ensure
    config.instance_variable_set(:@registry, original)
    config.on_missing_matcher = original_missing
  end

  def declare(name, &validator)
    dsl.scope(name, model: Role) do
      query { Role.all }
      validate(&validator)
    end
  end

  def grant(*scopes)
    create(:permission, role: role, model: 'Role', action: :create, scopes: scopes)
  end

  def decision(**options)
    Writ::Access.validation(subject: record, action: :create, context: context, **options)
  end

  it 'defers the query and validator and supplies only declared keywords' do
    calls = []
    dsl.scope(:named, model: Role, arguments: { name: { type: :string, required: true } }) do
      query do |arguments:|
        calls << [:query, arguments]
        Role.where(name: arguments.fetch('name'))
      end
      validate do |value, errors, context:, arguments:|
        calls << [:validate, context, arguments]
        errors.add(:name, :not_permitted, message: 'must remain a draft') unless value.name == arguments.fetch('name')
      end
    end
    expect(calls).to be_empty
    permission = create(:permission, role: role, model: 'Role', action: :create)
    scope = Scope.create!(model: 'Role', name: 'named')
    PermissionScope.create!(permission: permission, scope: scope, arguments: { name: 'Draft' })
    query = config.registry.get_scope_callable(model_name: 'Role', scope_name: 'named')
    expect(query.call(context, { 'name' => 'Draft' }).where_values_hash).to include('name' => 'Draft')
    result = decision
    expect(result).not_to be_allowed
    expect(result.errors).to contain_exactly(have_attributes(attribute: :name, type: :not_permitted,
                                                             options: { message: 'must remain a draft' }))
    expect(calls.last).to eq([:validate, context, { 'name' => 'Draft' }])
    expect(record.errors).to be_empty
  end

  it 'dispatches query context keywords through saved filtering' do
    visible = create(:role, name: 'Visible', organisation: organisation)
    create(:role, name: 'Hidden', organisation: organisation)
    dsl.scope(:visible, model: Role) do
      query { |context:| Role.where(organisation_id: context.organisation_id, name: 'Visible') }
    end
    create(:permission, role: role, model: 'Role', action: :read, scopes: [:visible])

    expect(Writ::Access.filter(context: context, action: :read, records: Role)).to contain_exactly(visible)
  end

  it 'uses errors rather than the validation callback return value' do
    declare(:accepted) { |_value, _errors| false }
    grant(:accepted)
    expect(decision).to be_allowed
  end

  it 'requires a query and rejects malformed callback signatures at declaration time' do
    expect { dsl.scope(:missing, model: Role) { validate { |_record, _errors| } } }
      .to raise_error(ArgumentError, /query/)
    expect { dsl.scope(:bad_query, model: Role) { query { |context| Role.all } } }
      .to raise_error(ArgumentError, /query/)
    expect { dsl.scope(:bad_validate, model: Role) { query { Role.all }; validate { |record| } } }
      .to raise_error(ArgumentError, /validate/)
  end

  it 'combines every scope within a grant and preserves its diagnostic errors' do
    declare(:name) { |_value, errors| errors.add(:name, :not_permitted, message: 'must be a draft') }
    declare(:description) { |_value, errors| errors.add(:description, :blank) }
    permission = grant(:name, :description)
    result = decision
    expect(result.errors.map(&:attribute)).to contain_exactly(:name, :description)
    expect(result.denied_grants).to contain_exactly(have_attributes(permission_id: permission.id, errors: result.errors))
  end

  it 'discards errors and denials from losing alternatives after any grant succeeds' do
    declare(:failed) { |_value, errors| errors.add(:name, :invalid) }
    declare(:accepted) { |_value, _errors| }
    grant(:failed)
    grant(:accepted)
    result = decision
    expect(result).to be_allowed
    expect(result.errors).to be_empty
    expect(result.denied_grants).to be_empty
    expect(record.errors).to be_empty
  end

  it 'reports a generic error for contradictory alternatives while retaining diagnostics' do
    declare(:draft) { |_value, errors| errors.add(:name, :invalid, message: 'must be draft') }
    declare(:published) { |_value, errors| errors.add(:name, :invalid, message: 'must be published') }
    grant(:draft)
    grant(:published)
    result = decision
    expect(result.errors.map(&:attribute)).to eq([:base])
    expect(result.denied_grants.map { |denial| denial.errors.first.options[:message] })
      .to contain_exactly('must be draft', 'must be published')
  end

  it 'cannot bypass a default boundary and presents identical shared errors' do
    dsl.default_scope(model: Role) do
      query { Role.all }
      validate { |_value, errors| errors.add(:organisation_id, :not_permitted, message: 'must stay in this organisation') }
    end
    declare(:first) { |_value, errors| errors.add(:name, :invalid) }
    declare(:second) { |_value, _errors| }
    grant(:first)
    grant(:second)
    result = decision
    expect(result).not_to be_allowed
    expect(result.errors.map(&:attribute)).to eq([:organisation_id])
    expect(result.denied_grants.length).to eq(2)
  end

  it 'preserves the default boundary when a later scope clears its own collector' do
    dsl.default_scope(model: Role) do
      query { Role.all }
      validate { |_value, errors| errors.add(:organisation_id, :not_permitted) }
    end
    declare(:independent) { |_value, errors| errors.clear }
    grant(:independent)

    result = decision
    expect(result).not_to be_allowed
    expect(result.errors.map(&:attribute)).to eq([:organisation_id])
  end

  it 'preserves earlier lifecycle denials when a collector callback clears its errors' do
    grant
    config.register_creation_validator(model_name: 'Role') { |context:, record:| false }
    config.register_creation_validator(model_name: 'Role') { |context:, record:, errors:| errors.clear }

    result = decision
    expect(result.reason).to eq(:validator_rejected)
    expect(result.errors.map(&:attribute)).to eq([:base])
  end

  it 'preflights missing validators even when another grant can succeed' do
    declare(:accepted) { |_value, _errors| }
    dsl.scope(:missing, model: Role) { query { Role.all } }
    grant(:accepted)
    grant(:missing)
    expect { decision }.to raise_error(Writ::ConfigurationError, /validate.*Role\/missing/)
  end

  it 'propagates validation exceptions' do
    declare(:broken) { |_value, _errors| raise 'host error' }
    grant(:broken)
    expect { decision }.to raise_error(RuntimeError, 'host error')
  end

  it 'freezes detached error snapshots and replaces only errors previously applied by Writ' do
    options = { message: 'must be draft', metadata: { values: ['draft'] } }
    declare(:draft) { |_value, errors| errors.add(:name, :not_permitted, **options) }
    grant(:draft)
    original = record.errors.add(:name, :not_permitted, message: 'must be draft')
    result = decision
    options[:metadata][:values] << 'published'
    expect(result.errors.first.options[:metadata][:values]).to eq(['draft'])
    expect { result.errors.first.options[:metadata][:values] << 'archived' }.to raise_error(FrozenError)
    2.times { result.apply_errors_to(record) }
    expect(record.errors.objects.length).to eq(2)
    expect(record.errors.objects.first).to equal(original)
    Writ::Access::CheckResult.new(allowed: true, reason: :granted).apply_errors_to(record)
    expect(record.errors.objects).to eq([original])
  end

  it 'detaches nested metadata containers without freezing host classes' do
    host_class = Class.new
    metadata = Struct.new(:choices).new(Set.new([['draft']]))
    snapshot = Writ::Access::ErrorSnapshot.new(attribute: :name, type: :invalid,
                                                options: { metadata: metadata, model: host_class })
    metadata.choices.first << 'published'

    expect(snapshot.options[:metadata].choices.first).to eq(['draft'])
    expect { snapshot.options[:metadata].choices.first << 'archived' }.to raise_error(FrozenError)
    expect(snapshot.options[:model]).to equal(host_class)
    expect(host_class).not_to be_frozen
  end

  it 'runs error-collector lifecycle callbacks once after a grant and ignores their return value' do
    grant
    calls = 0
    config.register_creation_validator(model_name: 'Role') do |context:, record:, errors:|
      calls += 1
      errors.add(:name, :blank) if record.name.empty?
      false
    end
    expect(decision).to be_allowed
    expect(calls).to eq(1)
    record.name = ''
    result = decision
    expect(result.reason).to eq(:validator_rejected)
    expect(result.errors.map(&:attribute)).to eq([:name])
    expect(record.errors).to be_empty
  end

  it 'checks only explicitly submitted field names when requested' do
    grant
    allow(Writ::Access).to receive(:input_fields).with(context: context, record: record, action: :create).and_return(['name'])
    expect(decision).to be_allowed
    expect(decision(submitted_fields: [:name])).to be_allowed
    result = decision(submitted_fields: [:name, :organisation_id])
    expect(result.reason).to eq(:forbidden_fields)
    expect(result.errors).to contain_exactly(have_attributes(attribute: :organisation_id, type: :not_permitted))
    expect(record.errors).to be_empty
  end
end
