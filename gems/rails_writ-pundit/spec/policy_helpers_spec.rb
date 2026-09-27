# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Writ::Pundit::PolicyHelpers do
  # Create a test policy class with proper singleton method definition
  let(:test_policy_class) do
    klass = Class.new do
      include Writ::Pundit::PolicyHelpers
    end
    klass.define_singleton_method(:name) { 'TestAssetPolicy' }
    klass.define_singleton_method(:policy_model) { Asset }
    klass
  end

  let(:test_registry) { Writ::Logic::Registry.new }

  before do
    allow(Writ::Configuration).to receive(:registry).and_return(test_registry)
    allow(Writ::Configuration).to receive(:register_scope) do |model_name:, scope_name:, arguments: {}, matches: nil, replace: false, declaration_location: nil, &block|
      test_registry.register_scope(model_name: model_name, scope_name: scope_name, arguments: arguments, matches: matches, replace: replace, declaration_location: declaration_location, &block)
    end
    allow(Writ::Configuration).to receive(:register_default_scope) do |model_name:, matches: nil, replace: false, declaration_location: nil, &block|
      test_registry.register_default_scope(model_name: model_name, matches: matches, replace: replace, declaration_location: declaration_location, &block)
    end
    allow(Writ::Configuration).to receive(:register_condition) do |name:, arguments: {}, replace: false, declaration_location: nil, &block|
      test_registry.register_condition(name: name, arguments: arguments, replace: replace, declaration_location: declaration_location, &block)
    end
    allow(Writ::Configuration).to receive(:register_permission) do |**args|
      test_registry.register_permission(**args)
    end
    allow(Writ::Configuration).to receive(:register_accessible_fields) do |**args|
      test_registry.register_accessible_fields(**args)
    end
    allow(Writ::Configuration).to receive(:register_role_description) do |**args|
      test_registry.register_role_description(**args)
    end
    allow(Writ::Configuration).to receive(:register_allow_missing_default_scope) do |model_name:|
      test_registry.allow_missing_default_scope(model_name: model_name)
    end
  end

  describe ".policy_model" do
    it "resolves model when overridden" do
      expect(test_policy_class.policy_model).to eq(Asset)
    end

    it "raises NameError for unknown model by default" do
      bad_policy = Class.new do
        include Writ::Pundit::PolicyHelpers
      end
      bad_policy.define_singleton_method(:name) { 'NonexistentModelPolicy' }

      expect { bad_policy.policy_model }.to raise_error(NameError, /could not resolve model/)
    end
  end

  describe ".role" do
    it "raises ArgumentError when role_name is blank" do
      expect {
        test_policy_class.role('') {}
      }.to raise_error(ArgumentError, /role_name is required/)
    end

    it "raises ArgumentError when role_name is nil" do
      expect {
        test_policy_class.role(nil) {}
      }.to raise_error(ArgumentError, /role_name is required/)
    end

    it "registers role description when provided" do
      test_policy_class.role(:TestRole, description: "A test role") {}
      expect(test_registry.role_description("TestRole")).to eq("A test role")
    end
  end

  describe ".permission" do
    it "raises ArgumentError when called outside a role block" do
      expect {
        test_policy_class.permission(:read)
      }.to raise_error(ArgumentError, /must be called within a role block/)
    end

    it "registers permission when inside a role block" do
      test_policy_class.role(:Tester) do
        permission :read
      end

      perms = test_registry.all_permissions
      expect(perms.dig("Tester", "Asset")).to include(hash_including(action: :read))
    end

    it "preserves inherited and lexical condition arguments" do
      policy = test_policy_class
      test_policy_class.requires_conditions(tenant_access: { tenant_id: 42 })

      test_policy_class.with_conditions(business_hours: { timezone: "UTC" }) do |_dsl|
        policy.role(:Tester) do
          policy.permission(:read, conditions: [{ device_trusted: { level: "strong" } }])
        end
      end

      permission = test_registry.all_permissions.dig("Tester", "Asset").first

      expect(permission[:conditions]).to eq(%w[business_hours device_trusted tenant_access])
      expect(permission[:condition_arguments]).to eq(
        "tenant_access" => { "tenant_id" => 42 },
        "business_hours" => { "timezone" => "UTC" },
        "device_trusted" => { "level" => "strong" }
      )
    end
  end

  describe ".accessible_fields" do
    it "raises ArgumentError when called outside a role block" do
      expect {
        test_policy_class.accessible_fields(:all)
      }.to raise_error(ArgumentError, /must be called within a role block/)
    end

    it "registers accessible fields when inside a role block" do
      test_policy_class.role(:Tester) do
        accessible_fields [:name, :status]
      end

      af = test_registry.all_accessible_fields
      expect(af.dig("Tester", "Asset")).to eq(%w[create read update delete].to_h { |action| [action, %w[name status]] })
    end
  end

  describe ".scope and .default_scope delegation (TEST-13)" do
    it "delegates scope to the internal ConfigurationDSL" do
      test_policy_class.scope(:delegated_test_scope) { Asset.all }
      expect(test_registry.scope_callable_registered?(model_name: 'Asset', scope_name: 'delegated_test_scope')).to be true
    end

    it "delegates default_scope to the internal ConfigurationDSL" do
      test_policy_class.default_scope { Asset.all }
      expect(test_registry.default_scope_registered?(model_name: 'Asset')).to be true
    end

    it "allows a policy to explicitly replace a scope, default scope, or condition" do
      test_policy_class.scope(:visible) { Asset.all }
      test_policy_class.default_scope { Asset.all }
      test_policy_class.condition(:active) { |_context| true }

      expect { test_policy_class.scope(:visible, replace: true) { Asset.none } }.not_to raise_error
      expect { test_policy_class.default_scope(replace: true) { Asset.none } }.not_to raise_error
      expect { test_policy_class.condition(:active, replace: true) { |_context| false } }.not_to raise_error
    end

    it "reports both policy declaration locations for a duplicate scope" do
      test_policy_class.scope(:visible) { Asset.all }

      error = begin
        test_policy_class.scope(:visible) { Asset.none }
      rescue Writ::ConfigurationError => exception
        exception
      end

      expect(error.message).to include('First declaration:', 'Conflicting declaration:')
      expect(error.message.scan(/policy_helpers_spec\.rb/).length).to eq(2)
    end

    it "rejects duplicate default scopes and conditions from policies" do
      test_policy_class.default_scope { Asset.all }
      test_policy_class.condition(:active) { |_context| true }

      expect {
        test_policy_class.default_scope { Asset.none }
      }.to raise_error(Writ::ConfigurationError, /default_scope on 'Asset'/)
      expect {
        test_policy_class.condition(:active) { |_context| false }
      }.to raise_error(Writ::ConfigurationError, /condition 'active'/)
    end

    it "allows a policy to exempt its model from the default scope requirement" do
      test_policy_class.allow_missing_default_scope
      test_policy_class.scope(:visible) { Asset.all }
      original_mode = Writ::Configuration.on_missing_default_scope
      Writ::Configuration.on_missing_default_scope = :raise

      expect { test_registry.reload_complete! }.not_to raise_error
    ensure
      Writ::Configuration.on_missing_default_scope = original_mode
    end

    it "registers the policy exemption again after a rebuild" do
      test_policy_class.allow_missing_default_scope
      test_registry.clear!
      test_policy_class.allow_missing_default_scope
      test_policy_class.scope(:visible) { Asset.all }
      original_mode = Writ::Configuration.on_missing_default_scope
      Writ::Configuration.on_missing_default_scope = :raise

      expect { test_registry.reload_complete! }.not_to raise_error
    ensure
      Writ::Configuration.on_missing_default_scope = original_mode
    end
  end

  describe ".condition delegation (TEST-14)" do
    it "delegates condition to the internal ConfigurationDSL" do
      test_policy_class.condition(:test_condition) { |context| true }
      expect(test_registry.condition_registered?(name: 'test_condition')).to be true
    end
  end

  describe ".field_resolver and validator delegation" do
    it "registers a model field resolver using policy_model" do
      resolver = ->(context:, action:, record:, fields:) { fields }

      test_policy_class.field_resolver(include_global: true, &resolver)

      expect(test_registry.field_resolver_for(model_name: 'Asset')).to include(callable: resolver, include_global: true)
    end

    it "reports both policy resolver declaration locations when declarations conflict" do
      first = ->(context:, action:, record:, fields:) { fields }
      second = ->(context:, action:, record:, fields:) { fields }

      test_policy_class.field_resolver(&first)

      error = begin
        test_policy_class.field_resolver(&second)
      rescue Writ::ConfigurationError => exception
        exception
      end

      expect(error.message).to include('First declaration:', 'Conflicting declaration:')
      expect(error.message.scan(/policy_helpers_spec\.rb/).length).to eq(2)
    end

    it "registers ordered creation and update validators" do
      first = ->(context:, record:) { true }
      second = ->(context:, record:) { false }
      update = ->(context:, record:) { true }

      test_policy_class.creation_validator(&first)
      test_policy_class.creation_validator(&second)
      test_policy_class.update_validator(&update)

      expect(test_registry.creation_validators_for(model_name: 'Asset')).to eq([first, second])
      expect(test_registry.update_validators_for(model_name: 'Asset')).to eq([update])
    end
  end

  describe "thread-safe role stack (DSL-2)" do
    it "supports nested role blocks" do
      test_policy_class.role(:Outer) do
        permission :read

        role(:Inner) do
          permission :create
        end
      end

      perms = test_registry.all_permissions
      expect(perms.dig("Outer", "Asset")).to include(hash_including(action: :read))
      expect(perms.dig("Inner", "Asset")).to include(hash_including(action: :create))
    end

    it "cleans up the stack even when an error occurs" do
      begin
        test_policy_class.role(:ErrorRole) do
          raise "test error"
        end
      rescue RuntimeError
        # Expected
      end

      # Stack should be clean
      expect(test_policy_class.role_stack).to be_empty
    end

    it "isolates role context between threads" do
      # Capture the class in a local variable accessible from the thread
      policy_class = test_policy_class
      barrier = Queue.new
      results = Queue.new

      thread = Thread.new do
        policy_class.role(:ThreadRole) do
          barrier.push(:ready)
          sleep 0.05 # Give main thread time to check
        end
        results.push(:done)
      end

      barrier.pop # Wait for thread to enter role block

      # Main thread should have empty stack
      expect(policy_class.role_stack).to be_empty

      thread.join
      expect(results.pop).to eq(:done)
    end
  end
end
