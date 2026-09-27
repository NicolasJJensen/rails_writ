require 'rails_helper'

RSpec.describe 'condition requirements in policy DSL' do
  let(:registry) { Writ::Logic::Registry.new }

  before do
    allow(Writ::Configuration).to receive(:registry).and_return(registry)
    allow(Writ::Configuration).to receive(:register_permission) do |**args|
      registry.register_permission(**args)
    end
  end

  def policy_class(name, base: Object)
    klass = Class.new(base) do
      include Writ::Pundit::PolicyHelpers unless ancestors.include?(Writ::Pundit::PolicyHelpers)
    end
    stub_const(name, klass)
    klass.define_singleton_method(:policy_model) { Asset }
    klass
  end

  it 'adds lexical conditions to permissions and merges nested blocks' do
    policy = policy_class('LexicalConditionsPolicy')

    policy.with_conditions(:in_office) do
      policy.with_conditions(:weekday) do
        policy.role(:Operator) { policy.permission(:read, conditions: [:explicit]) }
      end
    end

    permission = registry.all_permissions.dig('Operator', 'Asset').first
    expect(permission[:conditions]).to eq(%w[explicit in_office weekday])
  end

  it 'deduplicates identical inherited, lexical, and explicit references' do
    base = policy_class('RequirementBasePolicy')
    base.requires_conditions(:mfa_enabled)
    policy = policy_class('RequirementChildPolicy', base: base)

    policy.with_conditions(:mfa_enabled) do
      policy.role(:Operator) { policy.permission(:read, conditions: [:mfa_enabled]) }
    end

    permission = registry.all_permissions.dig('Operator', 'Asset').first
    expect(permission[:conditions]).to eq(['mfa_enabled'])
  end

  it 'deduplicates equivalent inherited arguments after key normalization' do
    base = policy_class('EquivalentArgumentBasePolicy')
    base.requires_conditions(gate: { tenant: { region: :au } })
    policy = policy_class('EquivalentArgumentChildPolicy', base: base)

    policy.role(:Operator) do
      permission(:read, conditions: [{ gate: { 'tenant' => { 'region' => :au } } }])
    end

    permission = registry.all_permissions.dig('Operator', 'Asset').first
    expect(permission[:conditions]).to eq(['gate'])
    expect(permission[:condition_arguments]).to eq(
      'gate' => { 'tenant' => { 'region' => :au } }
    )
  end

  it 'deduplicates equivalent lexical arguments after key normalization' do
    policy = policy_class('EquivalentLexicalArgumentPolicy')

    policy.with_conditions(gate: { tenant: { region: :au } }) do
      policy.role(:Operator) do
        policy.permission(:read, conditions: [{ gate: { 'tenant' => { 'region' => :au } } }])
      end
    end

    permission = registry.all_permissions.dig('Operator', 'Asset').first
    expect(permission[:conditions]).to eq(['gate'])
    expect(permission[:condition_arguments]).to eq(
      'gate' => { 'tenant' => { 'region' => :au } }
    )
  end

  it 'inherits requirements from a model-neutral abstract policy' do
    abstract = policy_class('AbstractMfaPolicy')
    abstract.requires_conditions(:mfa_enabled)
    child = policy_class('ConcreteAssetPolicy', base: abstract)

    child.role(:Operator) { child.permission(:read) }

    expect(registry.all_permissions.dig('Operator', 'Asset').first[:conditions]).to eq(['mfa_enabled'])
  end

  it 'rejects conflicting arguments for the same condition across layers' do
    policy = policy_class('ConflictingConditionsPolicy')

    expect do
      policy.with_conditions(mfa_enabled: { provider: 'webauthn' }) do
        policy.role(:Operator) do
          policy.permission(:read, conditions: [{ mfa_enabled: { provider: 'totp' } }])
        end
      end
    end.to raise_error(ArgumentError, /conflicting arguments.*mfa_enabled/i)
  end

  it 'preserves array order as semantic and does not mutate argument inputs' do
    policy = policy_class('OrderedConditionArgumentsPolicy')
    inherited = { tenant: { regions: %w[au nz] } }
    explicit = { 'tenant' => { 'regions' => %w[nz au] } }
    inherited_copy = Marshal.load(Marshal.dump(inherited))
    explicit_copy = Marshal.load(Marshal.dump(explicit))

    expect do
      policy.with_conditions(gate: inherited) do
        policy.role(:Operator) do
          policy.permission(:read, conditions: [{ gate: explicit }])
        end
      end
    end.to raise_error(ArgumentError, /conflicting arguments.*gate/i)

    expect(inherited).to eq(inherited_copy)
    expect(explicit).to eq(explicit_copy)
  end

  it 'rejects duplicate condition references within one declaration' do
    policy = policy_class('DuplicateConditionsPolicy')

    expect { policy.with_conditions(:mfa_enabled, :mfa_enabled) {} }
      .to raise_error(ArgumentError, /duplicate condition.*mfa_enabled/i)
  end

  it 'requires class requirements before local permissions' do
    policy = policy_class('LateRequirementsPolicy')
    policy.role(:Operator) { policy.permission(:read) }

    expect { policy.requires_conditions(:mfa_enabled) }
      .to raise_error(ArgumentError, /before permissions/i)
  end

  it 'keeps a with_conditions declaration scoped to its block' do
    policy = policy_class('ScopedConditionsPolicy')

    policy.with_conditions(:mfa_enabled) do
      policy.role(:Restricted) { policy.permission(:read) }
    end
    policy.role(:Public) { policy.permission(:read) }

    expect(registry.all_permissions.dig('Restricted', 'Asset').first[:conditions]).to eq(['mfa_enabled'])
    expect(registry.all_permissions.dig('Public', 'Asset').first[:conditions]).to eq([])
  end

  it 'restores the lexical stack when a nested declaration raises' do
    policy = policy_class('ExceptionSafeConditionsPolicy')

    expect do
      policy.with_conditions(:outer) do
        policy.with_conditions(:inner) { raise 'nested failure' }
      end
    end.to raise_error(RuntimeError, 'nested failure')

    policy.role(:Public) { policy.permission(:read) }

    expect(registry.all_permissions.dig('Public', 'Asset').first[:conditions]).to eq([])
  end
end
