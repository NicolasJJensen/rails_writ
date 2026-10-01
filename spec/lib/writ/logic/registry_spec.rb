require 'rails_helper'

RSpec.describe Writ::Logic::Registry do
  let(:registry) { Writ::Logic::Registry.new }
  let(:sample_proc) { ->(context) { User.where(id: context&.id) } }
  let(:sample_method) { :sample_filter_method }

  after do
    # Clean up any registrations after each test
    registry.clear!
    registry.reload_complete!
  end

  describe "#register_scope" do
    it "registers a scope callable with a block" do
      registry.register_scope(model_name: 'User', scope_name: 'active') do |context|
        User.where(active: true)
      end

      expect(registry.scope_callable_registered?(model_name: 'User', scope_name: 'active')).to be true
    end

    it "registers a scope callable with a proc" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)

      expect(registry.scope_callable_registered?(model_name: 'User', scope_name: 'active')).to be true
      expect(registry.get_scope_callable(model_name: 'User', scope_name: 'active')).to be_kind_of(Proc)
    end

    it "registers a scope callable with a block" do
      callable = ->(context) { User.where(id: context&.id) }
      registry.register_scope(model_name: 'User', scope_name: 'active', &callable)

      expect(registry.scope_callable_registered?(model_name: 'User', scope_name: 'active')).to be true
      expect(registry.get_scope_callable(model_name: 'User', scope_name: 'active')).to equal(callable)
    end

    it "raises error if no block or callable provided" do
      expect {
        registry.register_scope(model_name: 'User', scope_name: 'active')
      }.to raise_error(Writ::InvalidScopeError)
    end

    it "converts model and scope names to strings" do
      registry.register_scope(model_name: :User, scope_name: :active, &sample_proc)

      expect(registry.scope_callable_registered?(model_name: 'User', scope_name: 'active')).to be true
    end

    it "stores scope callables in nested hash structure" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
      registry.register_scope(model_name: 'User', scope_name: 'admin', &sample_proc)
      registry.register_scope(model_name: 'Asset', scope_name: 'public', &sample_proc)

      scope_callables = registry.all_scope_callables
      expect(scope_callables['User'].keys.count).to eq(2)
      expect(scope_callables['Asset'].keys.count).to eq(1)
    end

    it "validates scope name format" do
      expect {
        registry.register_scope(model_name: 'User', scope_name: 'Invalid Name') { |c| User.all }
      }.to raise_error(ArgumentError, /invalid/i)

      expect {
        registry.register_scope(model_name: 'User', scope_name: '123_scope') { |c| User.all }
      }.to raise_error(ArgumentError, /invalid/i)
    end

    it "stores callable, argument schema, and matcher as one definition" do
      callable = ->(context, args) { User.where(id: args[:id]) }
      matcher = ->(context, record, args) { record.id == args[:id] }

      registry.register_scope(
        model_name: 'User', scope_name: 'selected',
        arguments: { id: { type: :integer, required: true } }, matches: matcher,
        &callable
      )

      definition = registry.get_scope_definition(model_name: 'User', scope_name: 'selected')
      expect(definition).to include(callable: callable, arguments: { id: { type: :integer, required: true } }, matches: matcher)
    end

    it "snapshots a caller-owned argument schema without freezing the caller or callable" do
      callable = ->(context, args) { User.where(id: args[:id]) }
      schema = { id: { type: :integer, default: 1 } }

      registry.register_scope(model_name: 'User', scope_name: 'selected', arguments: schema, &callable)
      schema[:id][:required] = 'invalid'
      schema[:id][:default] = 99

      expect(registry.scope_arguments_schema(model_name: 'User', scope_name: 'selected'))
        .to eq(id: { type: :integer, default: 1 })
      expect(schema.frozen?).to be(false)
      expect(registry.get_scope_callable(model_name: 'User', scope_name: 'selected')).to equal(callable)
    end

    it "keeps schemas independent when a caller reuses and mutates one" do
      schema = { ids: { type: :array } }
      registry.register_scope(model_name: 'User', scope_name: 'first', arguments: schema) { |_context, _args| User.all }
      schema[:ids][:required] = true
      registry.register_scope(model_name: 'User', scope_name: 'second', arguments: schema) { |_context, _args| User.all }

      expect(registry.scope_arguments_schema(model_name: 'User', scope_name: 'first'))
        .to eq(ids: { type: :array })
      expect(registry.scope_arguments_schema(model_name: 'User', scope_name: 'second'))
        .to eq(ids: { type: :array, required: true })
    end

    it "does not expose the stored scope schema through the reader" do
      registry.register_scope(
        model_name: 'User', scope_name: 'selected',
        arguments: { id: { type: :integer, required: true } }
      ) { |_context, _args| User.all }

      returned_schema = registry.scope_arguments_schema(model_name: 'User', scope_name: 'selected')
      returned_schema[:id][:required] = false

      expect(registry.scope_arguments_schema(model_name: 'User', scope_name: 'selected'))
        .to eq(id: { type: :integer, required: true })
    end

    it "does not leave a partial definition when validation fails" do
      expect {
        registry.register_scope(
          model_name: 'User', scope_name: 'broken', &->(context, args) { User.all })
      }.to raise_error(ArgumentError, /dispatched positional arguments/)

      expect(registry.get_scope_definition(model_name: 'User', scope_name: 'broken')).to be_nil
      expect(registry.scope_callable_registered?(model_name: 'User', scope_name: 'broken')).to be(false)
      expect(registry.scope_arguments_schema(model_name: 'User', scope_name: 'broken')).to be_nil
      expect(registry.get_scope_matcher(model_name: 'User', scope_name: 'broken')).to be_nil
    end

    it "removes the complete scope definition" do
      registry.register_scope(model_name: 'User', scope_name: 'selected', matches: ->(_c, _r) { true }, &sample_proc)

      expect(registry.remove_scope(model_name: 'User', scope_name: 'selected')).to eq(sample_proc)
      expect(registry.get_scope_definition(model_name: 'User', scope_name: 'selected')).to be_nil
    end

    it "rejects the legacy callable keyword" do
      expect {
        registry.register_scope(model_name: 'User', scope_name: 'selected', callable: sample_proc)
      }.to raise_error(ArgumentError, /unknown keyword: :callable/)
    end
  end

  describe "legacy callable keyword rejection" do
    it "rejects it for default scopes" do
      expect {
        registry.register_default_scope(model_name: 'User', callable: sample_proc)
      }.to raise_error(ArgumentError, /unknown keyword: :callable/)
    end

    it "rejects it for conditions" do
      expect {
        registry.register_condition(name: 'active', callable: sample_proc)
      }.to raise_error(ArgumentError, /unknown keyword: :callable/)
    end

    it "rejects it for field resolvers" do
      expect {
        registry.register_field_resolver(model_name: 'User', callable: sample_proc)
      }.to raise_error(ArgumentError, /unknown keyword: :callable/)
    end

    it "rejects it for creation validators" do
      expect {
        registry.register_creation_validator(model_name: 'User', callable: sample_proc)
      }.to raise_error(ArgumentError, /unknown keyword: :callable/)
    end

    it "rejects it for update validators" do
      expect {
        registry.register_update_validator(model_name: 'User', callable: sample_proc)
      }.to raise_error(ArgumentError, /unknown keyword: :callable/)
    end
  end

  describe "model hook registration" do
    it "registers a model field resolver and records whether it includes global" do
      resolver = ->(context:, action:, record:, fields:) { fields }

      registry.register_field_resolver(model_name: 'Asset', include_global: true, &resolver)

      expect(registry.field_resolver_for(model_name: 'Asset')).to include(callable: resolver, include_global: true)
    end

    it "rejects a non-boolean include_global value" do
      expect {
        registry.register_field_resolver(model_name: 'Asset', include_global: 'yes', &->(**) { [] })
      }.to raise_error(ArgumentError, /include_global.*boolean/)
    end

    it "requires an explicit choice before changing a model resolver" do
      first = ->(context:, action:, record:, fields:) { fields }
      second = ->(context:, action:, record:, fields:) { :all }
      registry.register_field_resolver(model_name: 'Asset', &first)

      expect {
        registry.register_field_resolver(model_name: 'Asset', &second)
      }.to raise_error(Writ::ConfigurationError, /Duplicate declaration.*append: true.*replace: true/)

      expect(registry.field_resolver_for(model_name: 'Asset')[:callable]).to equal(first)
    end

    it "appends model resolvers in declaration order" do
      first = ->(context:, action:, record:, fields:) { fields }
      second = ->(context:, action:, record:, fields:) { :all }
      registry.register_field_resolver(model_name: 'Asset', &first)
      registry.register_field_resolver(model_name: 'Asset', append: true, &second)

      expect(registry.field_resolvers_for(model_name: 'Asset').pluck(:callable)).to eq([first, second])
    end

    it "replaces the complete resolver chain only when requested" do
      first = ->(context:, action:, record:, fields:) { fields }
      appended = ->(context:, action:, record:, fields:) { fields + ['computed'] }
      replacement = ->(context:, action:, record:, fields:) { :all }
      registry.register_field_resolver(model_name: 'Asset', &first)
      registry.register_field_resolver(model_name: 'Asset', append: true, &appended)
      registry.register_field_resolver(model_name: 'Asset', replace: true, &replacement)

      expect(registry.field_resolvers_for(model_name: 'Asset').pluck(:callable)).to eq([replacement])
    end

    it "rejects ambiguous append and replace options" do
      expect {
        registry.register_field_resolver(model_name: 'Asset', append: true, replace: true, &->(**) { [] })
      }.to raise_error(ArgumentError, /append: true and replace: true/)
    end

    it "accepts resolver Procs, lambdas, and Methods that Ruby can invoke with the hook keywords" do
      resolver_proc = proc { |**kwargs| kwargs[:fields] }
      resolver_lambda = ->(context:, action:, record:, fields:) { fields }
      resolver_method = method(:single_hash_hook)

      registry.register_field_resolver(model_name: 'ProcAsset', &resolver_proc)
      registry.register_field_resolver(model_name: 'LambdaAsset', &resolver_lambda)
      registry.register_field_resolver(model_name: 'MethodAsset', &resolver_method)

      expect(registry.field_resolver_for(model_name: 'ProcAsset')[:callable]).to equal(resolver_proc)
      expect(registry.field_resolver_for(model_name: 'LambdaAsset')[:callable]).to equal(resolver_lambda)
      expect(registry.field_resolver_for(model_name: 'MethodAsset')[:callable]).to be_a(Proc)
    end

    it "accepts non-lambda Procs without keyword parameters for validators" do
      creation = proc { |_payload| true }
      update = proc { |_payload| true }

      registry.register_creation_validator(&creation)
      registry.register_update_validator(&update)

      expect(registry.creation_validators_for(model_name: 'Asset')).to eq([creation])
      expect(registry.update_validators_for(model_name: 'Asset')).to eq([update])
    end

    it "rejects a resolver with missing or unexpected required keywords without retaining it" do
      invalid = ->(context:, action:, record:) { record }

      expect {
        registry.register_field_resolver(model_name: 'Asset', &invalid)
      }.to raise_error(ArgumentError, /field_resolver.*keyword|keyword.*field_resolver/i)

      expect(registry.field_resolver_for(model_name: 'Asset')).to be_nil
    end

    it "rejects hooks with strict required positional parameters" do
      invalid_resolver = ->(context, record) { record }
      invalid_validator = ->(context, record) { true }
      invalid_zero = -> { true }
      invalid_rest = ->(context, record, *rest) { record }
      invalid_method = method(:two_positional_hook)

      expect {
        registry.register_field_resolver(model_name: 'Asset', &invalid_resolver)
      }.to raise_error(ArgumentError, /field_resolver.*(parameter|positional)|((parameter|positional).*field_resolver)/i)
      expect {
        registry.register_creation_validator(&invalid_validator)
      }.to raise_error(ArgumentError, /creation_validator.*(parameter|positional)|((parameter|positional).*creation_validator)/i)
      expect {
        registry.register_update_validator(&invalid_zero)
      }.to raise_error(ArgumentError, /update_validator.*(parameter|positional)|((parameter|positional).*update_validator)/i)
      expect {
        registry.register_field_resolver(model_name: 'RestAsset', &invalid_rest)
      }.to raise_error(ArgumentError, /field_resolver.*(parameter|positional)|((parameter|positional).*field_resolver)/i)
      expect {
        registry.register_update_validator(&invalid_method)
      }.to raise_error(ArgumentError, /update_validator.*(parameter|positional)|((parameter|positional).*update_validator)/i)

      expect(registry.field_resolver_for(model_name: 'Asset')).to be_nil
      expect(registry.creation_validators_for(model_name: 'Asset')).to be_empty
    end

    it "rejects hooks that explicitly disallow keywords" do
      invalid_resolver = ->(**nil) { [] }
      invalid_validator = ->(**nil) { true }

      expect {
        registry.register_field_resolver(model_name: 'Asset', &invalid_resolver)
      }.to raise_error(ArgumentError, /field_resolver.*keyword|keyword.*field_resolver/i)
      expect {
        registry.register_update_validator(&invalid_validator)
      }.to raise_error(ArgumentError, /update_validator.*keyword|keyword.*update_validator/i)

      expect(registry.field_resolver_for(model_name: 'Asset')).to be_nil
      expect(registry.update_validators_for(model_name: 'Asset')).to be_empty
    end

    it "appends global and model validators in deterministic order" do
      global = ->(context:, record:) { true }
      local = ->(context:, record:) { true }

      registry.register_creation_validator(&global)
      registry.register_creation_validator(model_name: 'Asset', &local)

      expect(registry.creation_validators_for(model_name: 'Asset')).to eq([global, local])
    end

    it "does not mix validators between models and exposes no resolver when absent" do
      asset_validator = ->(context:, record:) { true }
      user_validator = ->(context:, record:) { true }

      registry.register_creation_validator(model_name: 'Asset', &asset_validator)
      registry.register_creation_validator(model_name: 'User', &user_validator)

      expect(registry.creation_validators_for(model_name: 'Asset')).to eq([asset_validator])
      expect(registry.creation_validators_for(model_name: 'User')).to eq([user_validator])
      expect(registry.field_resolver_for(model_name: 'Asset')).to be_nil
    end

    it "rebuilds model hooks without retaining registrations from the previous build" do
      old = ->(context:, action:, record:, fields:) { fields }
      fresh = ->(context:, action:, record:, fields:) { fields }
      registry.register_field_resolver(model_name: 'Asset', &old)

      registry.reload do
        registry.register_field_resolver(model_name: 'Asset', &fresh)
      end

      expect(registry.field_resolver_for(model_name: 'Asset')[:callable]).to equal(fresh)
    end
  end

  def single_hash_hook(payload)
    payload[:fields]
  end

  def two_positional_hook(context, record)
    record
  end

  describe "condition registration atomicity" do
    it "does not retain metadata or a callable after invalid registration" do
      expect {
        registry.register_condition(name: 'broken', &->(_a, _b) { true })
      }.to raise_error(ArgumentError, /dispatched positional arguments/)

      expect(registry.get_condition(name: 'broken')).to be_nil
      expect(registry.condition_arguments_schema(name: 'broken')).to be_nil
    end

    it "removes the callable and schema together" do
      registry.register_condition(name: 'temporary', arguments: { enabled: { type: :boolean } }) { |_context, _args| true }

      expect(registry.remove_condition(name: 'temporary')).to be_a(Proc)
      expect(registry.get_condition(name: 'temporary')).to be_nil
      expect(registry.condition_arguments_schema(name: 'temporary')).to be_nil
    end

    it "snapshots a caller-owned condition schema without freezing the caller" do
      callable = ->(_context, _args) { true }
      schema = { enabled: { type: :boolean } }

      registry.register_condition(name: 'enabled', arguments: schema, &callable)
      schema[:enabled][:max_length] = -1

      expect(registry.condition_arguments_schema(name: 'enabled'))
        .to eq(enabled: { type: :boolean })
      expect(schema.frozen?).to be(false)
      expect(registry.get_condition(name: 'enabled')).to equal(callable)
    end

    it "does not expose the stored condition schema through the reader" do
      registry.register_condition(
        name: 'enabled', arguments: { enabled: { type: :boolean, required: true } }
      ) { |_context, _args| true }

      returned_schema = registry.condition_arguments_schema(name: 'enabled')
      returned_schema[:enabled][:required] = false

      expect(registry.condition_arguments_schema(name: 'enabled'))
        .to eq(enabled: { type: :boolean, required: true })
    end

    it "keeps reused condition schemas independent across registrations" do
      schema = { enabled: { type: :boolean } }
      registry.register_condition(name: 'first', arguments: schema) { |_context, _args| true }
      schema[:enabled][:required] = true
      registry.register_condition(name: 'second', arguments: schema) { |_context, _args| true }

      expect(registry.condition_arguments_schema(name: 'first'))
        .to eq(enabled: { type: :boolean })
      expect(registry.condition_arguments_schema(name: 'second'))
        .to eq(enabled: { type: :boolean, required: true })
    end
  end

  describe "required condition argument templates" do
    it "allows a bare required condition reference as a tenant generation template" do
      registry.register_condition(
        name: 'tenant_gate', arguments: { ids: { type: :array, required: true } }
      ) { |_context, _args| true }
      registry.register_permission(
        role: 'TenantAdmin', model: 'Asset', action: :read,
        scopes: [], conditions: ['tenant_gate']
      )

      expect { registry.validate_references! }.not_to raise_error
    end

    it "still rejects supplied condition values with the wrong type at boot" do
      registry.register_condition(
        name: 'tenant_gate', arguments: { ids: { type: :array, required: true } }
      ) { |_context, _args| true }
      registry.register_permission(
        role: 'TenantAdmin', model: 'Asset', action: :read,
        scopes: [], conditions: ['tenant_gate'],
        condition_arguments: { tenant_gate: { ids: 'wrong' } }
      )

      expect { registry.validate_references! }
        .to raise_error(Writ::ConfigurationError, /tenant_gate.*array/i)
    end

  end

  describe "#get_scope_callable" do
    it "retrieves registered scope callable" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)

      callable = registry.get_scope_callable(model_name: 'User', scope_name: 'active')
      expect(callable).to eq(sample_proc)
    end

    it "returns nil for unregistered scope callable" do
      expect(registry.get_scope_callable(model_name: 'User', scope_name: 'nonexistent')).to be_nil
    end

    it "handles symbol parameters" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)

      callable = registry.get_scope_callable(model_name: :User, scope_name: :active)
      expect(callable).to eq(sample_proc)
    end
  end

  describe "#scope_callable_registered?" do
    it "returns true for registered scope callable" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)

      expect(registry.scope_callable_registered?(model_name: 'User', scope_name: 'active')).to be true
    end

    it "returns false for unregistered scope callable" do
      expect(registry.scope_callable_registered?(model_name: 'User', scope_name: 'nonexistent')).to be false
    end

    it "returns false for unregistered model" do
      expect(registry.scope_callable_registered?(model_name: 'UnknownModel', scope_name: 'active')).to be false
    end
  end

  describe "#scope_callables_for" do
    it "returns hash of scope callables for a model" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
      registry.register_scope(model_name: 'User', scope_name: 'admin', &sample_proc)

      scope_callables = registry.scope_callables_for(model_name: 'User')
      expect(scope_callables.keys.count).to eq(2)
      expect(scope_callables.keys).to include('active')
      expect(scope_callables.keys).to include('admin')
    end

    it "returns empty hash for model with no scope callables" do
      scope_callables = registry.scope_callables_for(model_name: 'UnknownModel')
      expect(scope_callables).to eq({})
    end
  end

  describe "#all_scope_callables" do
    it "returns all registered scope callables" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
      registry.register_scope(model_name: 'Asset', scope_name: 'public', &sample_proc)

      all_scope_callables = registry.all_scope_callables
      expect(all_scope_callables.keys.count).to eq(2)
      expect(all_scope_callables.keys).to include('User')
      expect(all_scope_callables.keys).to include('Asset')
    end

    it "returns a copy not the original" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)

      callables1 = registry.all_scope_callables
      callables2 = registry.all_scope_callables

      expect(callables1).not_to be(callables2)
    end
  end

  describe "#models" do
    it "returns list of models with scope callables" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
      registry.register_scope(model_name: 'Asset', scope_name: 'public', &sample_proc)
      registry.register_scope(model_name: 'Role', scope_name: 'admin', &sample_proc)

      models = registry.models
      expect(models.count).to eq(3)
      expect(models).to include('User')
      expect(models).to include('Asset')
      expect(models).to include('Role')
    end

    it "returns empty array when no scope callables registered" do
      expect(registry.models).to eq([])
    end
  end

  describe "#scopes_for" do
    it "returns list of scope names for a model" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
      registry.register_scope(model_name: 'User', scope_name: 'admin', &sample_proc)

      scopes = registry.scopes_for(model_name: 'User')
      expect(scopes.count).to eq(2)
      expect(scopes).to include('active')
      expect(scopes).to include('admin')
    end

    it "returns empty array for model with no scope callables" do
      scopes = registry.scopes_for(model_name: 'UnknownModel')
      expect(scopes).to eq([])
    end
  end

  describe "#register_default_scope / #get_default_scope / #default_scope_registered?" do
    it "registers and retrieves a default scope" do
      callable = ->(context) { "default result" }
      registry.register_default_scope(model_name: 'Asset', &callable)

      expect(registry.default_scope_registered?(model_name: 'Asset')).to be true
      expect(registry.get_default_scope(model_name: 'Asset')).to eq(callable)
    end

    it "returns nil for unregistered default scope" do
      expect(registry.get_default_scope(model_name: 'NonExistent')).to be_nil
      expect(registry.default_scope_registered?(model_name: 'NonExistent')).to be false
    end

    it "removes default scope" do
      registry.register_default_scope(model_name: 'Asset') { "default" }
      registry.remove_default_scope(model_name: 'Asset')
      expect(registry.default_scope_registered?(model_name: 'Asset')).to be false
    end

    it "rejects duplicate declarations outside of reload" do
      registry.register_default_scope(model_name: 'Asset') { "first" }
      registry.reload_complete!
      expect {
        registry.register_default_scope(model_name: 'Asset') { "second" }
      }.to raise_error(Writ::ConfigurationError, /Duplicate declaration/)
    end
  end

  describe "declaration conflicts" do
    it "rejects duplicate scopes with both declaration locations" do
      registry.register_scope(model_name: 'Asset', scope_name: 'visible', &sample_proc)

      error = begin
        registry.register_scope(model_name: 'Asset', scope_name: 'visible', &sample_proc)
      rescue Writ::ConfigurationError => exception
        exception
      end

      expect(error.message).to include("scope 'visible' on 'Asset'", 'First declaration:', 'Conflicting declaration:')
      expect(error.message.scan(/registry_spec\.rb/).length).to eq(2)
    end

    it "rejects duplicate default scopes and conditions" do
      registry.register_default_scope(model_name: 'Asset', &sample_proc)
      registry.register_condition(name: 'active', &->(_context) { true })

      default_scope_error = begin
        registry.register_default_scope(model_name: 'Asset', &sample_proc)
      rescue Writ::ConfigurationError => exception
        exception
      end
      condition_error = begin
        registry.register_condition(name: 'active', &->(_context) { false })
      rescue Writ::ConfigurationError => exception
        exception
      end

      expect(default_scope_error.message.scan(/registry_spec\.rb/).length).to eq(2)
      expect(condition_error.message.scan(/registry_spec\.rb/).length).to eq(2)
    end

    it "permits explicit replacement for scope, default scope, and condition" do
      first = ->(_context) { :first }
      replacement = ->(_context) { :replacement }
      registry.register_scope(model_name: 'Asset', scope_name: 'visible', &first)
      registry.register_default_scope(model_name: 'Asset', &first)
      registry.register_condition(name: 'active', &first)

      registry.register_scope(model_name: 'Asset', scope_name: 'visible', replace: true, &replacement)
      registry.register_default_scope(model_name: 'Asset', replace: true, &replacement)
      registry.register_condition(name: 'active', replace: true, &replacement)

      expect(registry.get_scope_callable(model_name: 'Asset', scope_name: 'visible')).to eq(replacement)
      expect(registry.get_default_scope(model_name: 'Asset')).to eq(replacement)
      expect(registry.get_condition(name: 'active')).to eq(replacement)
    end

    it "permits replacement during a successful rebuild" do
      first = ->(_context) { :first }
      replacement = ->(_context) { :replacement }

      expect {
        registry.reload do
          registry.register_default_scope(model_name: 'Asset', &first)
          registry.register_scope(model_name: 'Asset', scope_name: 'visible', &first)
          registry.register_scope(model_name: 'Asset', scope_name: 'visible', replace: true, &replacement)
        end
      }.not_to raise_error

      expect(registry.get_scope_callable(model_name: 'Asset', scope_name: 'visible')).to eq(replacement)
    end

    it "accepts repeated declarations during a fresh rebuild" do
      registry.register_scope(model_name: 'Asset', scope_name: 'visible', &sample_proc)

      expect {
        registry.reload do
          registry.register_scope(model_name: 'Asset', scope_name: 'visible', &sample_proc)
          registry.register_default_scope(model_name: 'Asset', &sample_proc)
        end
      }.not_to raise_error
    end
  end

  describe "Diagnostics (via Writ::Diagnostics)" do
    let(:diagnostics) { Writ::Diagnostics.new(registry) }

    describe "#statistics" do
      it "returns statistics about registered scope callables" do
        registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
        registry.register_scope(model_name: 'User', scope_name: 'admin', &sample_proc)
        registry.register_scope(model_name: 'Asset', scope_name: 'public', &sample_proc)

        stats = diagnostics.statistics

        expect(stats[:total_models]).to eq(2)
        expect(stats[:total_scope_callables]).to eq(3)
        expect(stats[:models]).to be_kind_of(Hash)
        expect(stats[:models]['User'][:scope_callable_count]).to eq(2)
        expect(stats[:models]['Asset'][:scope_callable_count]).to eq(1)
      end
    end

    describe "#inspect_registry" do
      it "returns formatted string representation" do
        registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)

        output = diagnostics.inspect_registry

        expect(output).to be_kind_of(String)
        expect(output).to include('User')
        expect(output).to include('active')
        expect(output).to include('Scope Callable Registry')
      end
    end
  end

  describe "#clear!" do
    it "removes all registered scope callables" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
      registry.register_scope(model_name: 'Asset', scope_name: 'public', &sample_proc)

      expect(registry.models.count).to eq(2)

      registry.clear!

      expect(registry.models.count).to eq(0)
      expect(registry.all_scope_callables).to eq({})
    end

    it "rejects duplicate declarations during reload" do
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
      registry.clear!
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)

      expect {
        registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
      }.to raise_error(Writ::ConfigurationError, /Duplicate declaration/)
    end

    it "rejects duplicate declarations after reload_complete!" do
      registry.clear!
      registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
      registry.register_default_scope(model_name: 'User', &sample_proc)
      registry.reload_complete!

      expect {
        registry.register_scope(model_name: 'User', scope_name: 'active', &sample_proc)
      }.to raise_error(Writ::ConfigurationError, /Duplicate declaration/)
    end
  end

  describe "condition registration" do
    let(:condition_proc) { ->(context) { Current.ip_address&.start_with?('192.168') } }

    describe "#register_condition" do
      it "registers a condition with a block" do
        registry.register_condition(name: 'in_office') do |context|
          Current.ip_address&.start_with?('192.168')
        end

        expect(registry.condition_registered?(name: 'in_office')).to be true
      end

      it "registers a condition with a block" do
        registry.register_condition(name: 'in_office', &condition_proc)

        expect(registry.condition_registered?(name: 'in_office')).to be true
      end

      it "raises error if no block provided" do
        expect {
          registry.register_condition(name: 'in_office')
        }.to raise_error(ArgumentError, /Block required/)
      end

      it "converts condition name to string" do
        registry.register_condition(name: :business_hours, &condition_proc)

        expect(registry.condition_registered?(name: 'business_hours')).to be true
      end

      it "stores conditions in flat hash structure" do
        registry.register_condition(name: 'business_hours', &condition_proc)
        registry.register_condition(name: 'in_office', &condition_proc)

        conditions = registry.all_conditions
        expect(conditions.count).to eq(2)
        expect(conditions).to include('business_hours', 'in_office')
      end

      it "validates callable arity" do
        bad_proc = ->(a, b) { true }
        expect {
          registry.register_condition(name: 'bad', &bad_proc)
        }.to raise_error(ArgumentError, /dispatched positional arguments/)
      end
    end

    describe "#get_condition" do
      it "retrieves registered condition" do
        registry.register_condition(name: 'in_office', &condition_proc)

        callable = registry.get_condition(name: 'in_office')
        expect(callable).to eq(condition_proc)
      end

      it "returns nil for unregistered condition" do
        expect(registry.get_condition(name: 'nonexistent')).to be_nil
      end

      it "handles symbol parameters" do
        registry.register_condition(name: 'in_office', &condition_proc)

        callable = registry.get_condition(name: :in_office)
        expect(callable).to eq(condition_proc)
      end
    end

    describe "#condition_registered?" do
      it "returns true for registered condition" do
        registry.register_condition(name: 'in_office', &condition_proc)

        expect(registry.condition_registered?(name: 'in_office')).to be true
      end

      it "returns false for unregistered condition" do
        expect(registry.condition_registered?(name: 'nonexistent')).to be false
      end

      it "handles symbol parameters" do
        registry.register_condition(name: 'in_office', &condition_proc)

        expect(registry.condition_registered?(name: :in_office)).to be true
      end
    end

    describe "#all_conditions" do
      it "returns empty array when no conditions registered" do
        expect(registry.all_conditions).to eq([])
      end

      it "returns array of condition names" do
        registry.register_condition(name: 'business_hours', &condition_proc)
        registry.register_condition(name: 'in_office', &condition_proc)

        conditions = registry.all_conditions
        expect(conditions).to be_a(Array)
        expect(conditions.count).to eq(2)
        expect(conditions).to include('business_hours', 'in_office')
      end
    end

    describe "condition evaluation" do
      it "can call registered condition with context" do
        registry.register_condition(name: 'in_office') do |context|
          Current.ip_address&.start_with?('192.168')
        end

        condition = registry.get_condition(name: 'in_office')
        Current.ip_address = '192.168.1.1'
        result = condition.call(nil)

        expect(result).to be true
      ensure
        Current.reset
      end

      it "condition returns false for non-matching context" do
        registry.register_condition(name: 'in_office') do |context|
          Current.ip_address&.start_with?('192.168')
        end

        condition = registry.get_condition(name: 'in_office')
        Current.ip_address = '10.0.0.1'
        result = condition.call(nil)

        expect(result).to be false
      ensure
        Current.reset
      end
    end

    describe "#clear!" do
      it "clears registered conditions" do
        registry.register_condition(name: 'business_hours', &condition_proc)
        registry.register_condition(name: 'in_office', &condition_proc)

        expect(registry.all_conditions.count).to eq(2)

        registry.clear!

        expect(registry.all_conditions.count).to eq(0)
      end
    end
  end

  describe "#register_permission" do
    it "rejects duplicate scope and condition argument keys before canonicalization" do
      expect do
        registry.register_permission(
          model: 'Asset', role: 'Admin', action: :read, scopes: [:selected],
          scope_arguments: { selected: { ids: [1], 'ids' => [2] } }
        )
      end.to raise_error(ArgumentError, /duplicate.*ids/i)

      expect do
        registry.register_permission(
          model: 'Asset', role: 'Admin', action: :read, scopes: [:selected],
          scope_arguments: { selected: { ids: [1] }, 'selected' => { ids: [2] } }
        )
      end.to raise_error(ArgumentError, /duplicate.*selected/i)

      expect do
        registry.register_permission(
          model: 'Asset', role: 'Admin', action: :read, scopes: [], conditions: [:allowed],
          condition_arguments: { allowed: { ids: [1], 'ids' => [2] } }
        )
      end.to raise_error(ArgumentError, /duplicate.*ids/i)
    end

    it "accepts JSON-style argument keys when they are unique" do
      registry.register_permission(
        model: 'Asset', role: 'Admin', action: :read, scopes: [:selected],
        scope_arguments: { 'selected' => { 'ids' => [1, 2] } }
      )

      expect(registry.all_permissions.dig('Admin', 'Asset').first[:scope_arguments]).to eq(
        'selected' => { 'ids' => [1, 2] }
      )
    end
    it "registers a permission with valid action" do
      registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [:service_industry])

      permissions = registry.all_permissions
      expect(permissions).to have_key("Admin")
      expect(permissions["Admin"]).to have_key("Asset")
    end

    it "accepts custom actions" do
      registry.register_permission(model: "Asset", role: "Admin", action: :view, scopes: [])
      permissions = registry.all_permissions
      expect(permissions["Admin"]["Asset"].first[:action]).to eq(:view)
    end

    it "rejects actions with special characters" do
      expect {
        registry.register_permission(model: "Asset", role: "Admin", action: :"read<script>", scopes: [])
      }.to raise_error(Writ::InvalidActionError)
    end

    it "converts model, role, and action to correct types" do
      registry.register_permission(model: :Asset, role: :Admin, action: :read, scopes: [:service_industry])

      permissions = registry.all_permissions
      expect(permissions).to have_key("Admin")
      expect(permissions["Admin"]).to have_key("Asset")

      perm = permissions["Admin"]["Asset"].first
      expect(perm[:action]).to eq(:read)
      expect(perm[:scopes]).to eq(["service_industry"])
    end

    it "stores conditions as strings" do
      registry.register_permission(
        model: "Asset", role: "Admin", action: :read,
        scopes: [], conditions: [:business_hours, :in_office]
      )

      perm = registry.all_permissions["Admin"]["Asset"].first
      expect(perm[:conditions]).to eq(%w[business_hours in_office])
    end

    it "appends multiple permissions for same role+model" do
      registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [])
      registry.register_permission(model: "Asset", role: "Admin", action: :create, scopes: [])

      perms = registry.all_permissions["Admin"]["Asset"]
      expect(perms.count).to eq(2)
      expect(perms.map { |p| p[:action] }).to contain_exactly(:read, :create)
    end

    it "warns on duplicate permission registration" do
      registry.reload_complete! # Ensure warnings are enabled

      registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [])

      expect(Rails.logger).to receive(:warn).with(/Duplicate permission registered/)
      registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [])

      # Should still only have one entry
      perms = registry.all_permissions["Admin"]["Asset"]
      expect(perms.count).to eq(1)
    end

    it "suppresses duplicate warnings during reload" do
      registry.clear! # Sets @reloading = true

      registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [])

      expect(Rails.logger).not_to receive(:warn)
      registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [])
    end
  end

  describe "#register_accessible_fields" do
    it "rejects false as an action instead of treating it as omitted" do
      expect {
        registry.register_accessible_fields(model: "Asset", role: "Admin", fields: [:name], action: false)
      }.to raise_error(ArgumentError, /Invalid field action/)
    end

    it "accepts string and symbol actions" do
      registry.register_accessible_fields(model: "Asset", role: "Admin", fields: [:name], action: :read)
      registry.register_accessible_fields(model: "Asset", role: "Admin", fields: [:status], action: "publish")

      expect(registry.all_accessible_fields["Admin"]["Asset"]).to include("read" => ["name"], "publish" => ["status"])
    end

    it "rejects non-string and non-symbol actions" do
      expect {
        registry.register_accessible_fields(model: "Asset", role: "Admin", fields: [:name], action: Object.new)
      }.to raise_error(ArgumentError, /Invalid field action/)
    end

    it "registers accessible fields for a role+model" do
      registry.register_accessible_fields(model: "Asset", role: "Admin", fields: [:name, :status])

      all_af = registry.all_accessible_fields
      expect(all_af).to have_key("Admin")
      expect(all_af["Admin"]).to have_key("Asset")
      expect(all_af["Admin"]["Asset"]).to eq(%w[create read update delete].to_h { |action| [action, %w[name status]] })
    end

    it "handles :all as the fields value" do
      registry.register_accessible_fields(model: "Asset", role: "Admin", fields: :all)

      expect(registry.all_accessible_fields["Admin"]["Asset"]).to eq(%w[create read update delete].to_h { |action| [action, nil] })
    end

    it "overwrites existing fields for same role+model" do
      registry.register_accessible_fields(model: "Asset", role: "Admin", fields: [:name])
      registry.register_accessible_fields(model: "Asset", role: "Admin", fields: [:name, :status])

      expect(registry.all_accessible_fields["Admin"]["Asset"]).to eq(%w[create read update delete].to_h { |action| [action, %w[name status]] })
    end

    it "validates fields type" do
      expect {
        registry.register_accessible_fields(model: "Asset", role: "Admin", fields: "all")
      }.to raise_error(ArgumentError, /fields must be :all or an Array/)

      expect {
        registry.register_accessible_fields(model: "Asset", role: "Admin", fields: { name: true })
      }.to raise_error(ArgumentError, /fields must be :all or an Array/)
    end
  end

  describe "#validate_references!" do
    it "raises ConfigurationError when a permission references an unregistered scope" do
      registry.register_scope(model_name: 'Asset', scope_name: 'good_scope', &sample_proc)
      registry.register_permission(model: 'Asset', role: 'Admin', action: :read, scopes: [:missing_scope])

      expect {
        registry.validate_references!
      }.to raise_error(Writ::ConfigurationError, /unregistered scope 'missing_scope'/)
    end

    it "raises ConfigurationError when a permission references an unregistered condition" do
      registry.register_scope(model_name: 'Asset', scope_name: 'good_scope', &sample_proc)
      registry.register_permission(model: 'Asset', role: 'Admin', action: :read, scopes: [:good_scope], conditions: [:missing_condition])

      expect {
        registry.validate_references!
      }.to raise_error(Writ::ConfigurationError, /unregistered condition 'missing_condition'/)
    end

    it "passes when all referenced scopes and conditions are registered" do
      registry.register_scope(model_name: 'Asset', scope_name: 'good_scope', &sample_proc)
      registry.register_default_scope(model_name: 'Asset', &sample_proc)
      registry.register_condition(name: 'good_condition') { true }
      registry.register_permission(model: 'Asset', role: 'Admin', action: :read, scopes: [:good_scope], conditions: [:good_condition])

      expect { registry.validate_references! }.not_to raise_error
    end
  end

  describe "scope definition metadata" do
    it "validates scope metadata name format" do
      expect {
        registry.register_scope(model_name: "Asset", scope_name: "Invalid Name") { User.all }
      }.to raise_error(ArgumentError, /invalid/i)

      expect {
        registry.register_scope(model_name: "Asset", scope_name: "123_bad") { User.all }
      }.to raise_error(ArgumentError, /invalid/i)
    end

    it "registers scope metadata for a model" do
      registry.register_scope(model_name: "Asset", scope_name: :service_industry) { User.all }

      metadata = registry.all_scope_metadata
      expect(metadata).to have_key("Asset")
      expect(metadata["Asset"]).to have_key("service_industry")
    end

    it "converts model and name to strings" do
      registry.register_scope(model_name: :User, scope_name: :current_location) { User.all }

      metadata = registry.all_scope_metadata
      expect(metadata).to have_key("User")
      expect(metadata["User"]).to have_key("current_location")
    end
  end

  describe "role descriptions" do
    it "registers and retrieves a role description" do
      registry.register_role_description(role: "Admin", description: "Full access administrator")

      expect(registry.role_description("Admin")).to eq("Full access administrator")
    end

    it "returns nil when no explicit description is registered" do
      description = registry.role_description("some_role")

      expect(description).to be_nil
    end

    it "reports explicit vs fallback descriptions" do
      expect(registry.role_description_explicit?("Admin")).to be false

      registry.register_role_description(role: "Admin", description: "Full access")

      expect(registry.role_description_explicit?("Admin")).to be true
    end

    it "clears role descriptions on clear!" do
      registry.register_role_description(role: "Admin", description: "Full access")
      registry.clear!

      expect(registry.role_description_explicit?("Admin")).to be false
    end
  end

  describe "#register_condition name validation (REG-5)" do
    it "rejects condition names with uppercase letters" do
      expect {
        registry.register_condition(name: 'InvalidName') { true }
      }.to raise_error(ArgumentError, /invalid/i)
    end

    it "rejects condition names starting with a number" do
      expect {
        registry.register_condition(name: '123_bad') { true }
      }.to raise_error(ArgumentError, /invalid/i)
    end

    it "rejects condition names with spaces" do
      expect {
        registry.register_condition(name: 'has spaces') { true }
      }.to raise_error(ArgumentError, /invalid/i)
    end

    it "accepts valid lowercase condition names" do
      expect {
        registry.register_condition(name: 'valid_name_123') { true }
      }.not_to raise_error
    end
  end

  describe "#register_permission input validation (REG-6)" do
    it "rejects non-array scopes" do
      expect {
        registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: :service_industry, conditions: [])
      }.to raise_error(ArgumentError, /scopes must be an Array/)
    end

    it "rejects non-array conditions" do
      expect {
        registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [], conditions: :business_hours)
      }.to raise_error(ArgumentError, /conditions must be an Array/)
    end

    it "rejects non-hash argument containers before mutating the registry" do
      expect {
        registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [],
                                     scope_arguments: :invalid)
      }.to raise_error(ArgumentError, /scope arguments must be a Hash/)

      expect(registry.all_permissions).to be_empty
    end

    it "rejects non-hash condition argument containers before mutating the registry" do
      expect {
        registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [],
                                     condition_arguments: :invalid)
      }.to raise_error(ArgumentError, /condition arguments must be a Hash/)

      expect(registry.all_permissions).to be_empty
    end

    it "preserves nil argument containers as empty arguments" do
      registry.register_permission(model: "Asset", role: "Admin", action: :read, scopes: [],
                                   scope_arguments: nil, condition_arguments: nil)

      expect(registry.all_permissions.dig("Admin", "Asset").first).to include(
        scope_arguments: {}, condition_arguments: {}
      )
    end
  end

  describe "#validate_references! collects all errors (REG-8)" do
    it "defers missing required condition values for bare and partial templates" do
      registry.register_condition(
        name: :tenant_gate, arguments: { ids: { type: :array, required: true }, mode: { type: :string, required: true } }
      ) { |_context, _args| true }
      registry.register_permission(model: 'Asset', role: 'Admin', action: :read,
                                   scopes: [], conditions: [:tenant_gate])
      registry.register_permission(model: 'Asset', role: 'Admin', action: :create,
                                   scopes: [], conditions: [:tenant_gate],
                                   condition_arguments: { tenant_gate: { ids: [1] } })

      expect { registry.validate_references! }.not_to raise_error
    end

    it "rejects supplied condition argument type and unknown key errors at boot" do
      registry.register_condition(name: :tenant_gate, arguments: { ids: { type: :array, required: true } }) { |_context, _args| true }
      registry.register_permission(model: 'Asset', role: 'Admin', action: :read,
                                   scopes: [], conditions: [:tenant_gate],
                                   condition_arguments: { tenant_gate: { ids: 'wrong', extra: true } })

      expect { registry.validate_references! }.to raise_error(Writ::ConfigurationError, /must be an array/)
      expect { registry.validate_references! }.to raise_error(Writ::ConfigurationError, /unknown argument 'extra'/)
    end

    it "reports multiple missing scopes and conditions in a single error" do
      registry.register_permission(model: 'Asset', role: 'Admin', action: :read, scopes: [:missing_scope_a, :missing_scope_b])
      registry.register_permission(model: 'Asset', role: 'Admin', action: :create, scopes: [], conditions: [:missing_cond])

      expect {
        registry.validate_references!
      }.to raise_error(Writ::ConfigurationError) do |error|
        expect(error.message).to include("missing_scope_a")
        expect(error.message).to include("missing_scope_b")
        expect(error.message).to include("missing_cond")
      end
    end
  end

  describe "#register_role_description validation (REG-10)" do
    it "rejects nil description" do
      expect {
        registry.register_role_description(role: "Admin", description: nil)
      }.to raise_error(ArgumentError, /non-empty String/)
    end

    it "rejects non-string description" do
      expect {
        registry.register_role_description(role: "Admin", description: 123)
      }.to raise_error(ArgumentError, /non-empty String/)
    end

    it "rejects empty string description" do
      expect {
        registry.register_role_description(role: "Admin", description: "")
      }.to raise_error(ArgumentError, /non-empty String/)
    end
  end

  describe "#remove_scope_callable cleans up scope_metadata (REG-R25-2)" do
    it "removes corresponding scope_metadata entry" do
      registry.register_scope(model_name: 'CleanMeta', scope_name: 'test_scope', &sample_proc)
      expect(registry.all_scope_metadata).to have_key('CleanMeta')

      registry.remove_scope_callable(model_name: 'CleanMeta', scope_name: 'test_scope')
      expect(registry.all_scope_metadata).not_to have_key('CleanMeta')
    end

    it "keeps other scope_metadata when removing one" do
      registry.register_scope(model_name: 'CleanMeta', scope_name: 'scope_a', &sample_proc)
      registry.register_scope(model_name: 'CleanMeta', scope_name: 'scope_b', &sample_proc)

      registry.remove_scope_callable(model_name: 'CleanMeta', scope_name: 'scope_a')
      expect(registry.all_scope_metadata['CleanMeta']).to have_key('scope_b')
      expect(registry.all_scope_metadata['CleanMeta']).not_to have_key('scope_a')
    end
  end

  describe "#remove_scope_callable cleans up empty model hashes (REG-11)" do
    it "removes the model key when no scopes remain" do
      registry.register_scope(model_name: 'Cleanup', scope_name: 'only_scope', &sample_proc)
      expect(registry.all_scope_callables).to have_key('Cleanup')

      registry.remove_scope_callable(model_name: 'Cleanup', scope_name: 'only_scope')
      expect(registry.all_scope_callables).not_to have_key('Cleanup')
    end

    it "keeps the model key when other scopes remain" do
      registry.register_scope(model_name: 'Cleanup', scope_name: 'scope_a', &sample_proc)
      registry.register_scope(model_name: 'Cleanup', scope_name: 'scope_b', &sample_proc)

      registry.remove_scope_callable(model_name: 'Cleanup', scope_name: 'scope_a')
      expect(registry.all_scope_callables).to have_key('Cleanup')
      expect(registry.all_scope_callables['Cleanup']).to have_key('scope_b')
    end
  end

  describe "#register_accessible_fields freezes arrays (REG-1)" do
    it "stores a frozen dup so the original input array cannot mutate stored data" do
      input = [:name, :status]
      registry.register_accessible_fields(model: "Asset", role: "Admin", fields: input)

      # Mutating the original input should not affect stored data
      input << :location
      stored = registry.all_accessible_fields["Admin"]["Asset"]
      expect(stored).to eq(%w[create read update delete].to_h { |action| [action, %w[name status]] })
      expect(stored.values.flatten).not_to include("location")
    end

    it "stores unrestricted CRUD actions as nil values" do
      registry.register_accessible_fields(model: "Asset", role: "Admin", fields: :all)
      stored = registry.all_accessible_fields["Admin"]["Asset"]
      expect(stored).to eq(%w[create read update delete].to_h { |action| [action, nil] })
    end
  end

  describe "validate_references! warns about models with scopes but no default_scope (TEST-6)" do
    before { allow(Writ::Configuration).to receive(:multi_tenant?).and_return(true) }
    it "logs a warning for models that have scopes but no default_scope" do
      original_mode = Writ::Configuration.on_missing_default_scope
      Writ::Configuration.on_missing_default_scope = :warning
      registry.register_scope(model_name: 'NoDefault', scope_name: 'some_scope', &sample_proc)

      expect(Rails.logger).to receive(:warn).with(/Model 'NoDefault' has scopes but no default_scope/)
      registry.reload_complete!
    ensure
      Writ::Configuration.on_missing_default_scope = original_mode
    end

    it "raises when the missing default scope mode is :raise" do
      original_mode = Writ::Configuration.on_missing_default_scope
      begin
        Writ::Configuration.on_missing_default_scope = :raise
        registry.register_scope(model_name: 'NoDefault', scope_name: 'some_scope', &sample_proc)

        expect { registry.reload_complete! }
          .to raise_error(Writ::ConfigurationError, /no default_scope/)
      ensure
        Writ::Configuration.on_missing_default_scope = original_mode
      end
    end

    it "does not log when the missing default scope mode is :skip" do
      original_mode = Writ::Configuration.on_missing_default_scope
      begin
        Writ::Configuration.on_missing_default_scope = :skip
        registry.register_scope(model_name: 'NoDefault', scope_name: 'some_scope', &sample_proc)

        expect(Rails.logger).not_to receive(:warn).with(/Model 'NoDefault' has scopes but no default_scope/)
        registry.reload_complete!
      ensure
        Writ::Configuration.on_missing_default_scope = original_mode
      end
    end

    it "does not require a default scope for an explicitly exempt model" do
      registry.allow_missing_default_scope(model_name: 'GlobalLookup')
      original_mode = Writ::Configuration.on_missing_default_scope
      Writ::Configuration.on_missing_default_scope = :raise
      registry.register_scope(model_name: 'GlobalLookup', scope_name: 'visible', &sample_proc)

      expect { registry.reload_complete! }.not_to raise_error
    ensure
      Writ::Configuration.on_missing_default_scope = original_mode
    end

    it "clears default-scope exemptions before the next rebuild" do
      original_mode = Writ::Configuration.on_missing_default_scope
      registry.allow_missing_default_scope(model_name: 'GlobalLookup')
      registry.clear!
      registry.register_scope(model_name: 'GlobalLookup', scope_name: 'visible', &sample_proc)
      Writ::Configuration.on_missing_default_scope = :raise

      expect { registry.reload_complete! }.to raise_error(Writ::ConfigurationError, /no default_scope/)
    ensure
      Writ::Configuration.on_missing_default_scope = original_mode
    end
  end

  describe "reload_complete! triggers validate_references! (TEST-19)" do
    it "raises ConfigurationError when permissions reference unregistered scopes" do
      registry.register_permission(model: 'Asset', role: 'Admin', action: :read, scopes: [:nonexistent_scope])

      expect {
        registry.reload_complete!
      }.to raise_error(Writ::ConfigurationError, /nonexistent_scope/)
    end
  end

  describe "condition declaration conflicts" do
    it "rejects duplicate declarations outside of reload" do
      registry.register_condition(name: 'overwrite_test') { true }
      registry.reload_complete!

      expect {
        registry.register_condition(name: 'overwrite_test') { false }
      }.to raise_error(Writ::ConfigurationError, /Duplicate declaration/)
    end

    it "rejects duplicate declarations during reload" do
      registry.clear!
      registry.register_condition(name: 'overwrite_test') { true }

      expect {
        registry.register_condition(name: 'overwrite_test') { false }
      }.to raise_error(Writ::ConfigurationError, /Duplicate declaration/)
    end
  end

  describe "register_accessible_fields overwrite warning (TEST-27)" do
    it "warns when overwriting accessible fields outside of reload" do
      registry.register_accessible_fields(model: 'Asset', role: 'Admin', fields: [:name])
      registry.reload_complete!

      expect(Rails.logger).to receive(:warn).with(/Overwriting accessible_fields/)
      registry.register_accessible_fields(model: 'Asset', role: 'Admin', fields: [:name, :status])
    end

    it "does not warn during reload" do
      registry.clear!
      registry.register_accessible_fields(model: 'Asset', role: 'Admin', fields: [:name])

      expect(Rails.logger).not_to receive(:warn).with(/Overwriting accessible_fields/)
      registry.register_accessible_fields(model: 'Asset', role: 'Admin', fields: [:name, :status])
    end
  end

  describe "reload block method (REG-13)" do
    it "resets @reloading even when block raises" do
      begin
        registry.reload do
          raise "test error"
        end
      rescue RuntimeError
        # Expected
      end

      registry.register_scope(model_name: 'Test', scope_name: 'test', &sample_proc)
      expect {
        registry.register_scope(model_name: 'Test', scope_name: 'test', &sample_proc)
      }.to raise_error(Writ::ConfigurationError, /Duplicate declaration/)
    end
  end

  describe "integration with Configuration" do
    after do
      Writ::Configuration.registry.remove_scope_callable(model_name: 'User', scope_name: 'test')
    end

    it "can be accessed via Configuration.registry" do
      config_registry = Writ::Configuration.registry

      expect(config_registry).to be_instance_of(Writ::Logic::Registry)
    end

    it "can register scope callables via Configuration" do
      Writ::Configuration.register_scope(model_name: 'User', scope_name: 'test') { |context| sample_proc.call(context) }

      expect(Writ::Configuration.scope_callable_registered?(model_name: 'User', scope_name: 'test')).to be true
    end
  end

  describe "validate_references! warns about orphan accessible_fields (TEST-R25-9)" do
    it "logs a warning when accessible_fields reference a model with no permissions" do
      registry.register_accessible_fields(model: 'OrphanModel', role: 'Admin', fields: :all)

      expect(Writ::Configuration.logger).to receive(:warn).with(
        /Role 'Admin' has accessible_fields for 'OrphanModel'.*Possible typo/
      )

      registry.validate_references!
    end

    it "does not warn when accessible_fields reference a model with permissions" do
      registry.register_scope(model_name: 'Asset', scope_name: 'test_scope', &sample_proc)
      registry.register_default_scope(model_name: 'Asset', &sample_proc)
      registry.register_permission(model: 'Asset', role: 'Admin', action: :read, scopes: ['test_scope'])
      registry.register_accessible_fields(model: 'Asset', role: 'Admin', fields: :all)

      expect(Writ::Configuration.logger).not_to receive(:warn).with(
        /has accessible_fields.*Possible typo/
      )

      # Allow the "no default_scope" warning through
      allow(Writ::Configuration.logger).to receive(:warn)

      registry.validate_references!
    end
  end

  describe "duplicate detection with different scope order (TEST-R26-18)" do
    it "detects duplicate permissions when scopes are in different order" do
      registry.register_permission(model: 'Asset', role: 'Admin', action: :read, scopes: [:scope_b, :scope_a])

      expect(Writ::Configuration.logger).to receive(:warn).with(/Duplicate permission/)

      registry.register_permission(model: 'Asset', role: 'Admin', action: :read, scopes: [:scope_a, :scope_b])
    end
  end

  describe "#reload skips validation on error (R24-REG-2)" do
    it "does not call validate_references! when the block raises" do
      expect {
        registry.reload do
          registry.register_permission(model: 'Asset', role: 'Admin', action: :read, scopes: ['nonexistent_scope'])
          raise "simulated policy load error"
        end
      }.to raise_error(RuntimeError, "simulated policy load error")

      # Registry should not be in reloading state
      expect(registry.instance_variable_get(:@reloading)).to be false
    end

    it "calls validate_references! when the block succeeds" do
      expect {
        registry.reload do
          registry.register_permission(model: 'Asset', role: 'Admin', action: :read, scopes: ['nonexistent_scope'])
        end
      }.to raise_error(Writ::ConfigurationError, /unregistered scope/)
    end
  end

  describe "#all_configured_models (T8)" do
    it "returns the union of models from scope_callables, default_scopes, scope_metadata, and permissions" do
      registry.register_scope(model_name: 'ModelA', scope_name: 'scope_a') { |ctx| nil }
      registry.register_default_scope(model_name: 'ModelB') { |ctx| nil }
      registry.register_scope(model_name: 'ModelC', scope_name: 'some_scope') { User.all }
      registry.register_permission(model: 'ModelD', role: 'Admin', action: :read, scopes: [])

      result = registry.all_configured_models

      expect(result).to include('ModelA', 'ModelB', 'ModelC', 'ModelD')
    end

    it "includes a model that only appears in permissions" do
      registry.register_permission(model: 'PermOnlyModel', role: 'Admin', action: :read, scopes: [])

      result = registry.all_configured_models

      expect(result).to include('PermOnlyModel')
    end

    it "deduplicates models appearing in multiple registries" do
      registry.register_scope(model_name: 'DupModel', scope_name: 'scope_x') { |ctx| nil }
      registry.register_default_scope(model_name: 'DupModel') { |ctx| nil }

      result = registry.all_configured_models

      expect(result.count('DupModel')).to eq(1)
    end

    it "includes models configured only through model-specific hooks and exemptions" do
      registry.register_accessible_fields(model: 'FieldsOnlyModel', role: 'Admin', fields: :all)
      registry.register_field_resolver(model_name: 'ResolverOnlyModel') { |context:, action:, record:, fields:| fields }
      registry.register_creation_validator(model_name: 'CreationOnlyModel') { |context:, record:| true }
      registry.register_update_validator(model_name: 'UpdateOnlyModel') { |context:, record:| true }
      registry.allow_missing_default_scope(model_name: 'ExemptOnlyModel')

      expect(registry.all_configured_models).to include(
        'FieldsOnlyModel', 'ResolverOnlyModel', 'CreationOnlyModel', 'UpdateOnlyModel', 'ExemptOnlyModel'
      )
    end

    it "ignores global hooks because they do not identify a model" do
      registry.register_field_resolver(model_name: nil, include_global: true) { |context:, action:, record:, fields:| fields }
      registry.register_creation_validator { |context:, record:| true }
      registry.register_update_validator { |context:, record:| true }

      expect(registry.all_configured_models).to eq([])
    end
  end
end
