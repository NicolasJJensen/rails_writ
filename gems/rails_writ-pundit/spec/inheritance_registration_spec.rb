# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Pundit rule inheritance registration' do
  let(:registry) { Writ::Logic::Registry.new }

  before do
    stub_const('PolicyVehicle', Class.new(ActiveRecord::Base) { self.table_name = 'assets' })
    stub_const('PolicyTruck', Class.new(PolicyVehicle))
    stub_const('PolicyDeliveryTruck', Class.new(PolicyTruck))
    allow(Writ::Configuration).to receive(:registry).and_return(registry)
    allow(Writ::Configuration).to receive(:multi_tenant?).and_return(false)
  end

  def define_policies
    stub_const('PolicyVehiclePolicy', Class.new(Writ::Pundit::Policy))
    stub_const('IntermediateVehiclePolicy', Class.new(PolicyVehiclePolicy))
    stub_const('PolicyTruckPolicy', Class.new(IntermediateVehiclePolicy))
    stub_const('PolicyDeliveryTruckPolicy', Class.new(PolicyTruckPolicy))
  end

  it 'discovers empty policies and skips intermediate policies without models' do
    define_policies
    Writ::Pundit::Policy.register_policy_inheritances!
    expect(registry.model_lineage(model_name: 'PolicyDeliveryTruck')).to eq(%w[PolicyDeliveryTruck PolicyTruck PolicyVehicle])
    expect { registry.validate_references! }.not_to raise_error
  end

  it 'resolves scopes used by child declarations after the complete policy set is loaded' do
    define_policies
    PolicyVehiclePolicy.scope(:owned) { query { PolicyVehicle.all } }
    PolicyVehiclePolicy.role(:Driver) { permission :read }
    PolicyTruckPolicy.role(:Driver) { permission :update, scopes: [:owned] }
    Writ::Pundit::Policy.register_policy_inheritances!

    expect(registry.scope_owner(model_name: 'PolicyTruck', scope_name: 'owned')).to eq('PolicyVehicle')
    expect(registry.all_permissions.fetch('Driver').fetch('PolicyTruck').map { |permission| permission[:action] }).to eq([:update])
    expect { registry.validate_references! }.not_to raise_error
  end

  it 'rebuilds empty-policy relationships without retaining obsolete policy classes' do
    define_policies
    Writ::Pundit::Policy.register_policy_inheritances!
    registry.clear!
    stub_const('PolicyTruckPolicy', Class.new(Writ::Pundit::Policy))
    stub_const('PolicyDeliveryTruckPolicy', Class.new(PolicyTruckPolicy))
    Writ::Pundit::Policy.register_policy_inheritances!
    expect(registry.model_lineage(model_name: 'PolicyDeliveryTruck')).to eq(%w[PolicyDeliveryTruck PolicyTruck])
  end

  it 'waits for policy_model overrides in class bodies before registering inheritance' do
    stub_const('PolicyOverrideExample', Module.new)
    PolicyOverrideExample.const_set(:Vehicle, PolicyVehicle)
    PolicyOverrideExample.const_set(:Truck, PolicyTruck)
    PolicyOverrideExample.module_eval <<~RUBY, __FILE__, __LINE__ + 1
      class VehiclePolicy < Writ::Pundit::Policy
      end

      class TruckPolicy < VehiclePolicy
        role(:Driver) { permission :read }

        def self.policy_model
          ::PolicyDeliveryTruck
        end
      end
    RUBY

    Writ::Pundit::Policy.register_policy_inheritances!
    expect(registry.model_lineage(model_name: 'PolicyTruck')).to eq(['PolicyTruck'])
    expect(registry.model_lineage(model_name: 'PolicyDeliveryTruck')).to eq(%w[PolicyDeliveryTruck PolicyVehicle])
  end

  it 'registers a complete policy ancestry when used outside Rails loading' do
    define_policies
    PolicyDeliveryTruckPolicy.new(nil, PolicyDeliveryTruck)
    expect(registry.model_lineage(model_name: 'PolicyDeliveryTruck')).to eq(%w[PolicyDeliveryTruck PolicyTruck PolicyVehicle])
  end

  it 'rejects unrelated models before a standalone policy can use inherited grants' do
    define_policies
    stub_const('UnrelatedPolicy', Class.new(PolicyVehiclePolicy))
    UnrelatedPolicy.define_singleton_method(:policy_model) { User }
    expect { UnrelatedPolicy.new(nil, User) }.to raise_error(Writ::ConfigurationError, /STI hierarchy/)
    expect(registry.model_lineage(model_name: 'User')).to eq(['User'])
  end

  it 'resolves model constants afresh rather than caching a stale class after reload' do
    define_policies
    original = PolicyVehiclePolicy.policy_model
    stub_const('PolicyVehicle', Class.new(ActiveRecord::Base) { self.table_name = 'assets' })
    expect(PolicyVehiclePolicy.policy_model).to equal(PolicyVehicle)
    expect(PolicyVehiclePolicy.policy_model).not_to equal(original)
  end
end
