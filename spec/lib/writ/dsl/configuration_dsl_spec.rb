require 'rails_helper'
require_relative '../../../../lib/writ/dsl/configuration_dsl'

RSpec.describe Writ::DSL::ConfigurationDSL do
  let(:test_registry) { Writ::Logic::Registry.new }
  let(:configuration) { Writ::Configuration }
  let(:dsl) { Writ::DSL::ConfigurationDSL.new(configuration) }

  around do |example|
    previous_registry = configuration.instance_variable_get(:@registry)
    previous_configure_blocks = configuration.instance_variable_get(:@configure_blocks)&.dup
    example.run
  ensure
    configuration.instance_variable_set(:@registry, previous_registry)
    configuration.instance_variable_set(:@configure_blocks, previous_configure_blocks)
  end

  before do
    # Redirect DSL registrations to a test-local registry so the global registry
    # (populated by policy files at boot) is never cleared. Without this, tests
    # running after this spec in random order would fail with MissingScopeError.
    allow(configuration).to receive(:registry).and_return(test_registry)
    allow(configuration).to receive(:register_scope) do |model_name:, scope_name:, arguments: {}, matches: nil, validate: nil, replace: false, declaration_location: nil, &block|
      test_registry.register_scope(model_name: model_name, arguments: arguments, scope_name: scope_name, matches: matches, validate: validate, replace: replace, declaration_location: declaration_location, &block)
    end
    allow(configuration).to receive(:register_default_scope) do |model_name:, matches: nil, validate: nil, replace: false, declaration_location: nil, &block|
      test_registry.register_default_scope(model_name: model_name, matches: matches, validate: validate, replace: replace, declaration_location: declaration_location, &block)
    end
    allow(configuration).to receive(:register_condition) do |name:, arguments: {}, replace: false, declaration_location: nil, &block|
      test_registry.register_condition(name: name, arguments: arguments, replace: replace, declaration_location: declaration_location, &block)
    end
    allow(configuration).to receive(:register_allow_missing_default_scope) do |model_name:|
      test_registry.allow_missing_default_scope(model_name: model_name)
    end
  end

  describe "#scope" do
    it "accepts valid lowercase scope names" do
      expect {
        dsl.scope(:valid_scope_123, model: Asset) { |records| records }
      }.not_to raise_error
    end

    it "rejects scope names with uppercase letters" do
      expect {
        dsl.scope(:InvalidName, model: Asset) { |records| records }
      }.to raise_error(ArgumentError, /invalid/i)
    end

    it "rejects scope names with spaces" do
      expect {
        dsl.scope(:"has spaces", model: Asset) { |records| records }
      }.to raise_error(ArgumentError, /invalid/i)
    end

    it "rejects scope names starting with a number" do
      expect {
        dsl.scope(:"123_scope", model: Asset) { |records| records }
      }.to raise_error(ArgumentError, /invalid/i)
    end

    it "requires a model" do
      expect {
        dsl.scope(:valid_name) { |records| records }
      }.to raise_error(ArgumentError, /model: required/)
    end

    it "requires a block" do
      expect {
        dsl.scope(:valid_name, model: Asset)
      }.to raise_error(ArgumentError, /Block required/)
    end
  end

  describe "#condition" do
    it "accepts valid lowercase condition names" do
      expect {
        dsl.condition(:business_hours) { |context| true }
      }.not_to raise_error
    end

    it "rejects condition names with uppercase letters" do
      expect {
        dsl.condition(:InvalidCondition) { |context| true }
      }.to raise_error(ArgumentError, /invalid/i)
    end

    it "rejects condition names starting with a number" do
      expect {
        dsl.condition(:"123_condition") { |context| true }
      }.to raise_error(ArgumentError, /invalid/i)
    end

    it "requires a block" do
      expect {
        dsl.condition(:valid_name)
      }.to raise_error(ArgumentError, /Block required/)
    end
  end

  describe "#on_missing_matcher setting" do
    it "forwards :skip and :raise through yielded configuration" do
      original = Writ::Configuration.on_missing_matcher
      begin
        dsl.instance_eval { self.on_missing_matcher = :skip }
        expect(Writ::Configuration.on_missing_matcher).to eq(:skip)
        dsl.instance_eval { self.on_missing_matcher = :raise }
        expect(Writ::Configuration.on_missing_matcher).to eq(:raise)
      ensure
        Writ::Configuration.on_missing_matcher = original
      end
    end

    it "forwards settings through the yielded-config style" do
      original = Writ::Configuration.on_missing_matcher
      begin
        Writ::Configuration.configure do |config|
          config.on_missing_matcher = :skip
        end
        expect(Writ::Configuration.on_missing_matcher).to eq(:skip)
      ensure
        Writ::Configuration.on_missing_matcher = original
      end
    end

    it "keeps invalid values rejected by Configuration" do
      expect {
        dsl.instance_eval { self.on_missing_matcher = :ignore }
      }.to raise_error(ArgumentError, /on_missing_matcher must be one of/)
    end
  end

  describe "#on_missing_default_scope setting" do
    it "forwards settings through the public configuration DSL" do
      original = Writ::Configuration.on_missing_default_scope
      begin
        Writ.configure do |config|
          config.on_missing_default_scope = :raise
        end

        expect(Writ::Configuration.on_missing_default_scope).to eq(:raise)
      ensure
        Writ::Configuration.on_missing_default_scope = original
      end
    end
  end

  describe "model hook registration" do
    it "registers a field resolver for the explicit model and preserves include_global" do
      resolver = ->(context:, action:, record:, fields:) { fields }

      dsl.field_resolver(model: Asset, include_global: true, &resolver)

      expect(test_registry.field_resolver_for(model_name: 'Asset')).to include(callable: resolver, include_global: true)
    end

    it "accepts context-only creation and update validators" do
      creation = ->(context:, record:) { true }
      update = ->(context:, record:) { true }

      dsl.creation_validator(model: Asset, &creation)
      dsl.update_validator(model: Asset, &update)

      expect(test_registry.creation_validators_for(model_name: 'Asset')).to eq([creation])
      expect(test_registry.update_validators_for(model_name: 'Asset')).to eq([update])
    end
  end

  describe "#with_options" do
    it "inherits model from enclosing block" do
      dsl.with_options(model: Asset) do
        scope(:test_inherited) { query { Asset.all } }
      end
      expect(test_registry.scope_callable_registered?(model_name: 'Asset', scope_name: 'test_inherited')).to be true
    end

    it "supports block-argument style (do |c|)" do
      dsl.with_options(model: Asset) do |c|
        c.scope(:arg_style_scope) { query { Asset.all } }
      end
      expect(test_registry.scope_callable_registered?(model_name: 'Asset', scope_name: 'arg_style_scope')).to be true
    end

    it "allows nested with_options to override" do
      dsl.with_options(model: Asset) do
        with_options(role: :Admin) do
          permission :read
        end
      end
      perms = test_registry.all_permissions
      expect(perms.dig("Admin", "Asset")).to be_present
    end

    it "supports three-level nesting where inner overrides outer" do
      dsl.with_options(model: Asset) do
        with_options(role: :Viewer) do
          permission :read

          with_options(role: :Editor) do
            permission :update
          end
        end
      end

      perms = test_registry.all_permissions

      # Viewer should have read on Asset
      expect(perms.dig("Viewer", "Asset")).to include(hash_including(action: :read))
      # Editor (inner override) should have update on Asset
      expect(perms.dig("Editor", "Asset")).to include(hash_including(action: :update))
      # Editor should NOT have read (that was under Viewer)
      editor_actions = (perms.dig("Editor", "Asset") || []).map { |p| p[:action] }
      expect(editor_actions).not_to include(:read)
    end
  end

  describe "with_options cleans up stack on error (TEST-24)" do
    it "restores option stack when block raises" do
      expect {
        dsl.with_options(model: Asset) do
          raise "test error"
        end
      }.to raise_error(RuntimeError, "test error")

      # Stack should be restored — can still use DSL normally
      expect {
        dsl.with_options(model: Asset) do
          scope(:recovery_scope) { query { Asset.all } }
        end
      }.not_to raise_error

      expect(test_registry.scope_callable_registered?(model_name: 'Asset', scope_name: 'recovery_scope')).to be true
    end
  end

  describe "with_options requires a block (DSL-R25-1)" do
    it "raises ArgumentError when called without a block" do
      expect {
        dsl.with_options(model: Asset)
      }.to raise_error(ArgumentError, /Block required/)
    end

    it "does not corrupt the option stack when called without a block" do
      expect {
        dsl.with_options(model: Asset)
      }.to raise_error(ArgumentError)

      # Stack should still be intact — subsequent calls work normally
      dsl.with_options(model: Asset) do
        scope(:after_no_block) { query { Asset.all } }
      end
      expect(test_registry.scope_callable_registered?(model_name: 'Asset', scope_name: 'after_no_block')).to be true
    end
  end

  describe "with_options rejects unknown keys (DSL-R26-1)" do
    it "raises ArgumentError for typos in option keys" do
      expect {
        dsl.with_options(mdoel: Asset) { permission :read }
      }.to raise_error(ArgumentError, /Unknown with_options key.*:mdoel/)
    end

    it "raises ArgumentError listing all unknown keys" do
      expect {
        dsl.with_options(mdoel: Asset, roal: :Admin) { permission :read }
      }.to raise_error(ArgumentError, /Unknown with_options key.*:mdoel.*:roal/)
    end

    it "accepts all valid keys without error" do
      expect {
        dsl.with_options(model: Asset, role: :Admin, scopes: [:x], conditions: [:y]) do
          permission :read
        end
      }.not_to raise_error
    end
  end

  describe "frozen DSL rejects with_options (DSL-1)" do
    it "raises when with_options is called on a frozen instance" do
      frozen_dsl = Writ::DSL::ConfigurationDSL.new(configuration).freeze

      expect {
        frozen_dsl.with_options(model: Asset) {}
      }.to raise_error(Writ::ConfigurationError, /frozen ConfigurationDSL/)
    end
  end

  describe "#default_scope" do
    it "registers a default scope for the model" do
      dsl.default_scope(model: Asset) { query { Asset.all } }
      expect(test_registry.default_scope_registered?(model_name: 'Asset')).to be true
    end

    it "requires model" do
      expect { dsl.default_scope { query { Asset.all } } }.to raise_error(ArgumentError, /model: required/)
    end

    it "requires a block" do
      expect { dsl.default_scope(model: Asset) }.to raise_error(ArgumentError, /Block required/)
    end

    it "passes replace to the default scope registration" do
      dsl.default_scope(model: Asset) { query { Asset.all } }
      expect { dsl.default_scope(model: Asset, replace: true) { query { Asset.none } } }.not_to raise_error
    end
  end

  describe "declaration replacement" do
    it "passes replace to scope and condition registrations" do
      dsl.scope(:visible, model: Asset) { query { Asset.all } }
      dsl.condition(:active) { |_context| true }

      expect { dsl.scope(:visible, model: Asset, replace: true) { query { Asset.none } } }.not_to raise_error
      expect { dsl.condition(:active, replace: true) { |_context| false } }.not_to raise_error
    end

    it "reports both configure declaration locations for a duplicate scope" do
      dsl.scope(:visible, model: Asset) { query { Asset.all } }

      error = begin
        dsl.scope(:visible, model: Asset) { query { Asset.none } }
      rescue Writ::ConfigurationError => exception
        exception
      end

      expect(error.message).to include('First declaration:', 'Conflicting declaration:')
      expect(error.message.scan(/configuration_dsl_spec\.rb/).length).to eq(2)
    end
  end

  describe "#allow_missing_default_scope" do
    before { allow(configuration).to receive(:multi_tenant?).and_return(true) }
    it "registers a per-model exemption" do
      dsl.allow_missing_default_scope(model: Asset)

      original_mode = Writ::Configuration.on_missing_default_scope
      Writ::Configuration.on_missing_default_scope = :raise
      test_registry.register_scope(model_name: 'Asset', scope_name: 'visible') { Asset.all }
      expect { test_registry.reload_complete! }.not_to raise_error
    ensure
      Writ::Configuration.on_missing_default_scope = original_mode
    end

    it "requires the configuration declaration on every rebuilt registry" do
      dsl.allow_missing_default_scope(model: Asset)
      test_registry.clear!
      test_registry.register_scope(model_name: 'Asset', scope_name: 'visible') { Asset.all }
      original_mode = Writ::Configuration.on_missing_default_scope
      Writ::Configuration.on_missing_default_scope = :raise

      expect { test_registry.reload_complete! }.to raise_error(Writ::ConfigurationError, /no default_scope/)

      test_registry.clear!
      dsl.allow_missing_default_scope(model: Asset)
      test_registry.register_scope(model_name: 'Asset', scope_name: 'visible') { Asset.all }
      expect { test_registry.reload_complete! }.not_to raise_error
    ensure
      Writ::Configuration.on_missing_default_scope = original_mode
    end
  end

  describe "#permission" do
    it "registers a permission with model and role" do
      dsl.permission(:read, model: Asset, role: :Admin)
      perms = test_registry.all_permissions
      expect(perms.dig("Admin", "Asset")).to include(hash_including(action: :read))
    end

    it "requires model" do
      expect { dsl.permission(:read, role: :Admin) }.to raise_error(ArgumentError, /model: required/)
    end

    it "requires role" do
      expect { dsl.permission(:read, model: Asset) }.to raise_error(ArgumentError, /role: required/)
    end

    it "requires action to be a symbol" do
      expect { dsl.permission("read", model: Asset, role: :Admin) }.to raise_error(ArgumentError, /action must be a single symbol/)
    end

    it "accepts custom actions" do
      dsl.permission(:view, model: Asset, role: :Admin)
      perms = test_registry.all_permissions
      expect(perms["Admin"]["Asset"].first[:action]).to eq(:view)
    end

    it "rejects actions with special characters" do
      expect {
        dsl.permission(:"bad action!", model: Asset, role: :Admin)
      }.to raise_error(ArgumentError, /Invalid action/)
    end

    it "coerces scopes to array via Array() (R-13)" do
      dsl.permission(:read, model: Asset, role: :Admin, scopes: :service_industry)
      perms = test_registry.all_permissions
      expect(perms["Admin"]["Asset"].first[:scopes]).to eq(["service_industry"])
    end

    it "coerces conditions to array via Array() (R-13)" do
      dsl.permission(:read, model: Asset, role: :Admin, conditions: :business_hours)
      perms = test_registry.all_permissions
      expect(perms["Admin"]["Asset"].first[:conditions]).to eq(["business_hours"])
    end
  end

  describe "#accessible_fields" do
    it "rejects false as an action instead of treating it as omitted" do
      expect {
        dsl.accessible_fields([:name], model: Asset, role: :Admin, action: false)
      }.to raise_error(ArgumentError, /Invalid field action/)
    end

    it "accepts string and symbol actions" do
      dsl.accessible_fields([:name], model: Asset, role: :Admin, action: :read)
      dsl.accessible_fields([:status], model: Asset, role: :Admin, action: "publish")

      expect(test_registry.all_accessible_fields["Admin"]["Asset"]).to include(
        "read" => ["name"], "publish" => ["status"]
      )
    end

    it "rejects non-string and non-symbol actions" do
      expect {
        dsl.accessible_fields([:name], model: Asset, role: :Admin, action: Object.new)
      }.to raise_error(ArgumentError, /Invalid field action/)
    end

    it "accepts :all" do
      expect {
        dsl.accessible_fields(:all, model: Asset, role: :Admin)
      }.not_to raise_error
    end

    it "accepts an empty array" do
      expect {
        dsl.accessible_fields([], model: Asset, role: :Admin)
      }.not_to raise_error
    end

    it "accepts an array of symbols" do
      expect {
        dsl.accessible_fields([:name, :status], model: Asset, role: :Admin)
      }.not_to raise_error
    end

    it "rejects a string" do
      expect {
        dsl.accessible_fields("all", model: Asset, role: :Admin)
      }.to raise_error(ArgumentError, /fields must be :all or an Array/)
    end

    it "rejects a hash" do
      expect {
        dsl.accessible_fields({ name: true }, model: Asset, role: :Admin)
      }.to raise_error(ArgumentError, /fields must be :all or an Array/)
    end

    it "requires a model" do
      expect {
        dsl.accessible_fields(:all, role: :Admin)
      }.to raise_error(ArgumentError, /model: required/)
    end

    it "requires a role" do
      expect {
        dsl.accessible_fields(:all, model: Asset)
      }.to raise_error(ArgumentError, /role: required/)
    end
  end

  describe "with_options scope inheritance for permissions (R24-TEST-5)" do
    it "inherits scopes from enclosing with_options" do
      dsl.with_options(model: Asset, role: :Admin, scopes: [:inherited_scope]) do
        permission :read
      end
      perms = test_registry.all_permissions
      expect(perms["Admin"]["Asset"].first[:scopes]).to eq(["inherited_scope"])
    end

    it "allows permission to override inherited scopes" do
      dsl.with_options(model: Asset, role: :Admin, scopes: [:default_scope]) do
        permission :read, scopes: [:override_scope]
      end
      perms = test_registry.all_permissions
      expect(perms["Admin"]["Asset"].first[:scopes]).to eq(["override_scope"])
    end

    it "inherits model from outer with_options when inner only sets role (TEST-R26-10)" do
      dsl.with_options(model: Asset, role: :Admin) do
        with_options(role: :Viewer) do
          permission :read
        end
      end
      perms = test_registry.all_permissions
      expect(perms).to have_key("Viewer")
      expect(perms["Viewer"]).to have_key("Asset")
      expect(perms["Viewer"]["Asset"].first[:action]).to eq(:read)
    end

    it "inherits conditions from enclosing with_options" do
      dsl.with_options(model: Asset, role: :Admin, conditions: [:inherited_cond]) do
        permission :read
      end
      perms = test_registry.all_permissions
      expect(perms["Admin"]["Asset"].first[:conditions]).to eq(["inherited_cond"])
    end

    it "merges inherited, nested, and explicit condition arguments" do
      dsl.with_conditions(tenant_access: { tenant_id: 42 }) do
        permission :read,
          model: Asset,
          role: :Admin,
          conditions: [
            { business_hours: { timezone: "UTC" } },
            { device_trusted: { level: "strong" } }
          ]
      end

      permission = test_registry.all_permissions["Admin"]["Asset"].first

      expect(permission[:conditions]).to eq(%w[business_hours device_trusted tenant_access])
      expect(permission[:condition_arguments]).to eq(
        "tenant_access" => { "tenant_id" => 42 },
        "business_hours" => { "timezone" => "UTC" },
        "device_trusted" => { "level" => "strong" }
      )
    end
  end
end
