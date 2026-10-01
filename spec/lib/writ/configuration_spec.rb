require 'rails_helper'

RSpec.describe Writ::Configuration do
  after do
    registry = Writ::Configuration.registry
    registry.remove_scope_callable(model_name: "TestModel", scope_name: "test_scope")
    registry.remove_scope_callable(model_name: "TestModel2", scope_name: "test_scope")
    registry.remove_scope_callable(model_name: "TestModel3", scope_name: "existing")
  end

  describe ".registry" do
    it "returns a registry instance" do
      expect(Writ::Configuration.registry).to be_instance_of(Writ::Logic::Registry)
    end

    it "memoizes the registry" do
      expect(Writ::Configuration.registry).to eq(Writ::Configuration.registry)
    end

    it "rejects the legacy callable keyword for a field resolver" do
      test_registry = Writ::Logic::Registry.new
      allow(Writ::Configuration).to receive(:registry).and_return(test_registry)
      expect {
        Writ::Configuration.register_field_resolver(
          model_name: 'Asset', callable: ->(**) { [] }
        ) { |_context| [] }
      }.to raise_error(ArgumentError, /unknown keyword: :callable/)
    end
  end

  describe ".register_scope" do
    it "registers a scope callable in the registry" do
      Writ::Configuration.register_scope(model_name: "TestModel", scope_name: "test_scope") do |context|
        User.all
      end
      expect(Writ::Configuration.scope_callable_registered?(model_name: "TestModel", scope_name: "test_scope")).to be true
    end
  end

  describe ".get_scope_callable" do
    it "retrieves a registered scope callable from the registry" do
      block = ->(context) { User.all }
      Writ::Configuration.register_scope(model_name: "TestModel2", scope_name: "test_scope", &block)
      result = Writ::Configuration.get_scope_callable(model_name: "TestModel2", scope_name: "test_scope")
      expect(result).to eq(block)
    end
  end

  describe ".scope_callable_registered?" do
    it "checks if a scope callable is registered" do
      expect(Writ::Configuration.scope_callable_registered?(model_name: "TestModel3", scope_name: "nonexistent")).to be false
      Writ::Configuration.register_scope(model_name: "TestModel3", scope_name: "existing") { |context| User.all }
      expect(Writ::Configuration.scope_callable_registered?(model_name: "TestModel3", scope_name: "existing")).to be true
    end
  end

  describe "configuration is loaded" do
    it "has registry available" do
      expect(Writ::Configuration.registry).not_to be_nil
    end
  end

  describe ".on_missing_condition" do
    it "accepts :raise" do
      original = Writ::Configuration.on_missing_condition
      begin
        expect { Writ::Configuration.on_missing_condition = :raise }.not_to raise_error
      ensure
        Writ::Configuration.on_missing_condition = original
      end
    end

    it "accepts :deny" do
      original = Writ::Configuration.on_missing_condition
      begin
        expect { Writ::Configuration.on_missing_condition = :deny }.not_to raise_error
      ensure
        Writ::Configuration.on_missing_condition = original
      end
    end

    it "rejects invalid values" do
      expect {
        Writ::Configuration.on_missing_condition = :ignore
      }.to raise_error(ArgumentError, /on_missing_condition must be one of/)
    end

    it "rejects string values" do
      expect {
        Writ::Configuration.on_missing_condition = "raise"
      }.to raise_error(ArgumentError, /on_missing_condition must be one of/)
    end
  end

  describe ".on_missing_matcher" do
    it "defaults to :raise" do
      expect(Writ::Configuration.on_missing_matcher).to eq(:raise)
    end

    it "accepts :raise, :warning, and :skip" do
      original = Writ::Configuration.on_missing_matcher
      begin
        expect { Writ::Configuration.on_missing_matcher = :raise }.not_to raise_error
        expect { Writ::Configuration.on_missing_matcher = :warning }.not_to raise_error
        expect { Writ::Configuration.on_missing_matcher = :skip }.not_to raise_error
      ensure
        Writ::Configuration.on_missing_matcher = original
      end
    end

    it "rejects invalid values" do
      expect {
        Writ::Configuration.on_missing_matcher = :ignore
      }.to raise_error(ArgumentError, /on_missing_matcher must be one of/)
    end
  end

  describe ".on_missing_default_scope" do
    it "defaults to :raise" do
      expect(Writ::Configuration.on_missing_default_scope).to eq(:raise)
    end

    it "accepts :raise, :warning, and :skip" do
      original = Writ::Configuration.on_missing_default_scope
      begin
        %i[raise warning skip].each do |mode|
          expect { Writ::Configuration.on_missing_default_scope = mode }.not_to raise_error
        end
      ensure
        Writ::Configuration.on_missing_default_scope = original
      end
    end

    it "rejects invalid values" do
      expect {
        Writ::Configuration.on_missing_default_scope = :ignore
      }.to raise_error(ArgumentError, /on_missing_default_scope must be one of/)
    end

    it "keeps :raise as the effective default for single-tenant configuration" do
      original_multi_tenant = Writ::Configuration.multi_tenant
      original_mode = Writ::Configuration.instance_variable_get(:@on_missing_default_scope)
      begin
        Writ::Configuration.multi_tenant = false
        Writ::Configuration.instance_variable_set(:@on_missing_default_scope, nil)

        expect(Writ::Configuration.on_missing_default_scope).to eq(:raise)
      ensure
        Writ::Configuration.multi_tenant = original_multi_tenant
        Writ::Configuration.instance_variable_set(:@on_missing_default_scope, original_mode)
      end
    end

    it "keeps an explicit strict mode in single-tenant configuration" do
      original_multi_tenant = Writ::Configuration.multi_tenant
      original_mode = Writ::Configuration.instance_variable_get(:@on_missing_default_scope)
      begin
        Writ::Configuration.multi_tenant = false
        Writ::Configuration.on_missing_default_scope = :raise

        expect(Writ::Configuration.on_missing_default_scope).to eq(:raise)
      ensure
        Writ::Configuration.multi_tenant = original_multi_tenant
        Writ::Configuration.instance_variable_set(:@on_missing_default_scope, original_mode)
      end
    end
  end

  describe "model hook rebuild lifecycle" do
    it "records configure blocks once, replays their original code before policy loading, and keeps the last successful registry" do
      original_registry = Writ::Configuration.registry
      original_blocks = Writ::Configuration.instance_variable_get(:@configure_blocks)&.dup
      Writ::Configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
      Writ::Configuration.instance_variable_set(:@configure_blocks, [])
      stub_const('LifecycleConfiguredFirstModel', Class.new)
      stub_const('LifecycleConfiguredSecondModel', Class.new)
      configured_model = LifecycleConfiguredFirstModel
      validator = ->(context:, record:) { true }

      Writ::Configuration.configure do |config|
        config.default_scope(model: configured_model) { |_context| [] }
        config.scope(:current_model, model: configured_model) { |_context| [] }
        config.creation_validator(&validator)
      end

      expect(Writ::Configuration.scope_callable_registered?(model_name: 'LifecycleConfiguredFirstModel', scope_name: 'current_model')).to be(true)
      expect(Writ::Configuration.instance_variable_get(:@configure_blocks)).to have_attributes(length: 1)

      configured_model = LifecycleConfiguredSecondModel
      seen_before_policy_loading = false
      Writ::Configuration.rebuild! do
        seen_before_policy_loading = Writ::Configuration.scope_callable_registered?(model_name: 'LifecycleConfiguredSecondModel', scope_name: 'current_model')
      end
      published = Writ::Configuration.registry

      expect(seen_before_policy_loading).to be(true)
      expect(published.scope_callable_registered?(model_name: 'LifecycleConfiguredFirstModel', scope_name: 'current_model')).to be(false)
      expect(published.creation_validators_for(model_name: 'Anything')).to eq([validator])
      expect(Writ::Configuration.instance_variable_get(:@configure_blocks)).to have_attributes(length: 1)

      Writ::Configuration.rebuild!
      before_failed_rebuild = Writ::Configuration.registry
      expect(before_failed_rebuild.creation_validators_for(model_name: 'Anything')).to eq([validator])
      expect(Writ::Configuration.instance_variable_get(:@configure_blocks)).to have_attributes(length: 1)

      expect {
        Writ::Configuration.rebuild! { raise 'broken policy load' }
      }.to raise_error(RuntimeError, 'broken policy load')
      expect(Writ::Configuration.registry).to equal(before_failed_rebuild)
      expect(Writ::Configuration.registry.creation_validators_for(model_name: 'Anything')).to eq([validator])
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry) if original_registry
      Writ::Configuration.instance_variable_set(:@configure_blocks, original_blocks)
    end

    it "does not record a configure block that fails before its declarations are valid" do
      original_registry = Writ::Configuration.registry
      original_blocks = Writ::Configuration.instance_variable_get(:@configure_blocks)&.dup
      Writ::Configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
      Writ::Configuration.instance_variable_set(:@configure_blocks, [])

      expect {
        Writ::Configuration.configure do |config|
          config.field_resolver(model: Asset, include_global: 'yes') { |**| [] }
        end
      }.to raise_error(ArgumentError, /include_global.*boolean/)

      expect(Writ::Configuration.instance_variable_get(:@configure_blocks)).to eq([])
      expect(Writ::Configuration.registry.field_resolver_for(model_name: 'Asset')).to be_nil
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry) if original_registry
      Writ::Configuration.instance_variable_set(:@configure_blocks, original_blocks)
    end

    it "leaves the published registry and replay blocks unchanged when a later declaration fails" do
      original_registry = Writ::Configuration.registry
      original_blocks = Writ::Configuration.instance_variable_get(:@configure_blocks)&.dup
      Writ::Configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
      Writ::Configuration.instance_variable_set(:@configure_blocks, [])

      Writ::Configuration.configure do |config|
        config.scope(:existing, model: Asset) { query { Asset.all } }
      end
      published = Writ::Configuration.registry
      blocks = Writ::Configuration.instance_variable_get(:@configure_blocks).dup

      expect {
        Writ::Configuration.configure do |config|
          config.scope(:partial, model: Asset) { query { Asset.all } }
          config.field_resolver(model: Asset, include_global: 'invalid') { |**| [] }
        end
      }.to raise_error(ArgumentError, /include_global.*boolean/)

      expect(Writ::Configuration.registry).to equal(published)
      expect(published.scope_callable_registered?(model_name: 'Asset', scope_name: 'existing')).to be(true)
      expect(published.scope_callable_registered?(model_name: 'Asset', scope_name: 'partial')).to be(false)
      expect(Writ::Configuration.instance_variable_get(:@configure_blocks)).to eq(blocks)
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry) if original_registry
      Writ::Configuration.instance_variable_set(:@configure_blocks, original_blocks)
    end

    it "does not replay direct registry registrations across rebuilding" do
      original_registry = Writ::Configuration.registry
      original_blocks = Writ::Configuration.instance_variable_get(:@configure_blocks)&.dup
      Writ::Configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
      Writ::Configuration.instance_variable_set(:@configure_blocks, [])
      validator = ->(context:, record:) { true }

      Writ::Configuration.register_creation_validator(&validator)
      expect(Writ::Configuration.registry.creation_validators_for(model_name: 'Asset')).to eq([validator])

      Writ::Configuration.rebuild!
      expect(Writ::Configuration.registry.creation_validators_for(model_name: 'Asset')).to eq([])
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry) if original_registry
      Writ::Configuration.instance_variable_set(:@configure_blocks, original_blocks)
    end

  end

  describe ".on_condition_error" do
    it "accepts :raise" do
      original = Writ::Configuration.on_condition_error
      begin
        expect { Writ::Configuration.on_condition_error = :raise }.not_to raise_error
      ensure
        Writ::Configuration.on_condition_error = original
      end
    end

    it "accepts :deny" do
      original = Writ::Configuration.on_condition_error
      begin
        expect { Writ::Configuration.on_condition_error = :deny }.not_to raise_error
      ensure
        Writ::Configuration.on_condition_error = original
      end
    end

    it "rejects invalid values" do
      expect {
        Writ::Configuration.on_condition_error = :ignore
      }.to raise_error(ArgumentError, /on_condition_error must be one of/)
    end

    it "rejects string values" do
      expect {
        Writ::Configuration.on_condition_error = "raise"
      }.to raise_error(ArgumentError, /on_condition_error must be one of/)
    end
  end

  describe ".configure" do
    it "yields a ConfigurationDSL instance" do
      original_registry = Writ::Configuration.registry
      test_registry = Writ::Logic::Registry.new
      original_blocks = Writ::Configuration.instance_variable_get(:@configure_blocks)&.dup
      allow(Writ::Configuration).to receive(:registry).and_return(test_registry)

      Writ::Configuration.configure do |config|
        config.scope(:configure_test, model: Asset) { query { Asset.all } }
      end

      expect(test_registry.scope_callable_registered?(model_name: 'Asset', scope_name: 'configure_test')).to be true
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry)
      Writ::Configuration.instance_variable_set(:@configure_blocks, original_blocks)
    end
  end

  describe "custom class configuration error paths (TEST-9)" do
    it "raises ConfigurationError when permission class cannot be resolved" do
      original = Writ::Configuration.instance_variable_get(:@permission_class)
      begin
        # Set a class that will resolve but then clear and stub to fail
        Writ::Configuration.instance_variable_set(:@permission_class, nil)
        allow(Writ::Configuration).to receive(:permission_class).and_call_original
        stub_const('Writ::Configuration::PERMISSION_CLASS_NAME', 'NonexistentPermission')

        # Directly test the error path by temporarily hiding the Permission constant
        hide_const('Permission')

        expect {
          Writ::Configuration.permission_class
        }.to raise_error(Writ::ConfigurationError, /Writ could not find the Permission model/)
      ensure
        Writ::Configuration.instance_variable_set(:@permission_class, original)
      end
    end

    it "raises ConfigurationError when role class cannot be resolved (T5)" do
      original = Writ::Configuration.instance_variable_get(:@role_class)
      begin
        Writ::Configuration.instance_variable_set(:@role_class, nil)
        hide_const('Role')

        expect {
          Writ::Configuration.role_class
        }.to raise_error(Writ::ConfigurationError, /Writ could not find the Role model/)
      ensure
        Writ::Configuration.instance_variable_set(:@role_class, original)
      end
    end

  end

  describe ".reset!" do
    it "clears memoized class references" do
      # Force memoization
      Writ::Configuration.permission_class
      Writ::Configuration.role_class

      # Reset should clear them
      Writ::Configuration.reset!

      # After reset, they should re-resolve (not stale)
      expect(Writ::Configuration.permission_class).to eq(Permission)
      expect(Writ::Configuration.role_class).to eq(Role)
    ensure
      # Restore registry state by re-loading policies
      Dir[Rails.root.join('app/policies/**/*.rb')].each { |f| load f }
      Writ::Configuration.registry.reload_complete!
    end

    it "clears the registry (R24-TEST-3)" do
      Writ::Configuration.registry.register_condition(name: 'reset_test_cond') { true }
      expect(Writ::Configuration.registry.condition_registered?(name: 'reset_test_cond')).to be true

      Writ::Configuration.reset!

      expect(Writ::Configuration.registry.condition_registered?(name: 'reset_test_cond')).to be false
    ensure
      Dir[Rails.root.join('app/policies/**/*.rb')].each { |f| load f }
      Writ::Configuration.registry.reload_complete!
    end

    it "preserves config values across reset (R24-TEST-4)" do
      original_role = Writ::Configuration.default_role_name
      original_condition = Writ::Configuration.on_missing_condition

      begin
        Writ::Configuration.default_role_name = 'Test Role'
        Writ::Configuration.on_missing_condition = :deny

        Writ::Configuration.reset!

        expect(Writ::Configuration.default_role_name).to eq('Test Role')
        expect(Writ::Configuration.on_missing_condition).to eq(:deny)
      ensure
        Writ::Configuration.default_role_name = original_role
        Writ::Configuration.instance_variable_set(:@on_missing_condition, original_condition == :raise ? nil : original_condition)
        Dir[Rails.root.join('app/policies/**/*.rb')].each { |f| load f }
        Writ::Configuration.registry.reload_complete!
      end
    end

    it "accepts a block and calls reload_complete! automatically (A7)" do
      Writ::Configuration.registry.register_condition(name: 'block_reset_test') { true }

      Writ::Configuration.reset! do
        # Re-register during the block
        Writ::Configuration.registry.register_condition(name: 'block_reset_survivor') { true }
      end

      # The condition registered before reset! should be gone
      expect(Writ::Configuration.registry.condition_registered?(name: 'block_reset_test')).to be false
      # The condition registered inside the block should survive
      expect(Writ::Configuration.registry.condition_registered?(name: 'block_reset_survivor')).to be true
    ensure
      Dir[Rails.root.join('app/policies/**/*.rb')].each { |f| load f }
      Writ::Configuration.registry.reload_complete!
    end
  end

  describe ".role_description_with_fallback (T6)" do
    it "returns the registry description when one is registered" do
      registry = Writ::Configuration.registry
      registry.register_role_description(role: 'TestDescRole', description: 'A custom description')

      result = Writ::Configuration.role_description_with_fallback('TestDescRole')
      expect(result).to eq('A custom description')
    end

    it "falls back to I18n/humanized name when no description is registered" do
      result = Writ::Configuration.role_description_with_fallback('unregistered_role')
      expect(result).to eq('Unregistered role')
    end
  end
end
