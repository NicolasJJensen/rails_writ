# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Writ::Diagnostics do
  describe "#statistics" do
    it "returns model count and scope callable counts from registry" do
      test_registry = Writ::Logic::Registry.new
      test_registry.register_scope(model_name: 'Asset', scope_name: 'service_industry') { |c| Asset.all }
      test_registry.register_scope(model_name: 'Asset', scope_name: 'location') { |c| Asset.all }
      test_registry.register_scope(model_name: 'User', scope_name: 'organisation') { |c| User.all }

      diagnostics = Writ::Diagnostics.new(test_registry)
      stats = diagnostics.statistics

      expect(stats[:total_models]).to eq(2)
      expect(stats[:total_scope_callables]).to eq(3)
      expect(stats[:models]['Asset'][:scope_callable_count]).to eq(2)
      expect(stats[:models]['Asset'][:scopes]).to contain_exactly('service_industry', 'location')
      expect(stats[:models]['User'][:scope_callable_count]).to eq(1)
    end

    it "returns zero counts for empty registry" do
      test_registry = Writ::Logic::Registry.new
      diagnostics = Writ::Diagnostics.new(test_registry)
      stats = diagnostics.statistics

      expect(stats[:total_models]).to eq(0)
      expect(stats[:total_scope_callables]).to eq(0)
      expect(stats[:models]).to be_empty
    end
  end

  describe "#inspect_registry" do
    it "returns a formatted string representation of the registry" do
      test_registry = Writ::Logic::Registry.new
      test_registry.register_scope(model_name: 'Asset', scope_name: 'service_industry') { |c| Asset.all }

      diagnostics = Writ::Diagnostics.new(test_registry)
      output = diagnostics.inspect_registry

      expect(output).to include('Asset')
      expect(output).to include('service_industry')
      expect(output).to include('Proc')
    end

    it "includes conditions when registered" do
      test_registry = Writ::Logic::Registry.new
      test_registry.register_condition(name: 'business_hours') { |ctx| true }

      diagnostics = Writ::Diagnostics.new(test_registry)
      output = diagnostics.inspect_registry

      expect(output).to include('Conditions')
      expect(output).to include('business_hours')
    end
  end
end
