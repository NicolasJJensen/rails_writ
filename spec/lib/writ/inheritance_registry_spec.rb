# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Inherited rule registration and storage' do
  let(:registry) { Writ::Logic::Registry.new }

  before do
    stub_const('InheritanceVehicle', Class.new(ActiveRecord::Base) do
      self.table_name = 'assets'
      self.inheritance_column = 'description'
    end)
    stub_const('InheritanceTruck', Class.new(InheritanceVehicle))
    stub_const('InheritanceVan', Class.new(InheritanceVehicle))
    stub_const('InheritanceDeliveryTruck', Class.new(InheritanceTruck))
    allow(Writ::Configuration).to receive(:registry).and_return(registry)
    allow(Writ::Configuration).to receive(:multi_tenant?).and_return(false)
  end

  def inherit_rules
    registry.register_model_inheritance(model_name: 'InheritanceTruck', parent_model_name: 'InheritanceVehicle')
    registry.register_model_inheritance(model_name: 'InheritanceDeliveryTruck', parent_model_name: 'InheritanceTruck')
  end

  it 'registers core inheritance without copying parent grants' do
    dsl = Writ::DSL::ConfigurationDSL.new(Writ::Configuration)
    dsl.inherit_rules(model: InheritanceTruck, from: InheritanceVehicle)
    dsl.permission(:read, model: InheritanceVehicle, role: :Driver)

    expect(Writ::Configuration.authorization_models_for(InheritanceTruck)).to eq([InheritanceTruck, InheritanceVehicle])
    expect(registry.all_permissions.fetch('Driver').keys).to eq(['InheritanceVehicle'])
    expect(registry.model_lineage(model_name: 'InheritanceVan')).to eq(['InheritanceVan'])
    expect { registry.validate_references! }.not_to raise_error
  end

  it 'preserves explicit authorization model resolver behavior' do
    inherit_rules
    allow(Writ::Configuration).to receive(:authorization_model_resolver).and_return(->(_model) { InheritanceVehicle })
    expect(Writ::Configuration.authorization_models_for(InheritanceDeliveryTruck)).to eq([InheritanceVehicle])
  end

  it 'treats an explicit identity resolver as exact-model mode and restores normal inheritance with the default' do
    inherit_rules
    original = Writ::Configuration.authorization_model_resolver
    Writ::Configuration.authorization_model_resolver = ->(model) { model }
    expect(Writ::Configuration.custom_authorization_model_resolver?).to be(true)
    expect(Writ::Configuration.authorization_models_for(InheritanceTruck)).to eq([InheritanceTruck])
    Writ::Configuration.authorization_model_resolver = Writ::Configuration::DEFAULT_AUTHORIZATION_MODEL_RESOLVER
    expect(Writ::Configuration.custom_authorization_model_resolver?).to be(false)
    expect(Writ::Configuration.authorization_models_for(InheritanceTruck)).to eq([InheritanceTruck, InheritanceVehicle])
  ensure
    Writ::Configuration.authorization_model_resolver = original
  end

  it 'rejects unrelated models, cycles and conflicting parents' do
    expect { registry.register_model_inheritance(model_name: 'InheritanceTruck', parent_model_name: 'User') }
      .to raise_error(Writ::ConfigurationError, /STI hierarchy/)
    registry.register_model_inheritance(model_name: 'InheritanceTruck', parent_model_name: 'InheritanceVehicle')
    expect { registry.register_model_inheritance(model_name: 'InheritanceTruck', parent_model_name: 'InheritanceVan') }
      .to raise_error(Writ::ConfigurationError, /already inherits/)
    registry.register_model_inheritance(model_name: 'UnloadedChild', parent_model_name: 'UnloadedParent')
    expect { registry.register_model_inheritance(model_name: 'UnloadedParent', parent_model_name: 'UnloadedChild') }
      .to raise_error(Writ::ConfigurationError, /cycle/)
    expect { registry.validate_references! }.to raise_error(Writ::ConfigurationError, /STI hierarchy/)
  end

  it 'copies inheritance independently and clears it on reload' do
    inherit_rules
    copy = registry.dup_for_configuration
    registry.clear!
    expect(registry.model_lineage(model_name: 'InheritanceTruck')).to eq(['InheritanceTruck'])
    expect(copy.model_lineage(model_name: 'InheritanceDeliveryTruck'))
      .to eq(%w[InheritanceDeliveryTruck InheritanceTruck InheritanceVehicle])
  end

  it 'resolves scope arguments through ancestors while keeping getters exact' do
    inherit_rules
    registry.register_scope(model_name: 'InheritanceVehicle', scope_name: 'selected',
                            arguments: { id: { type: :integer, required: true } }) { |_context, args| InheritanceVehicle.where(id: args[:id]) }
    registry.register_permission(model: 'InheritanceDeliveryTruck', role: 'Driver', action: :read,
                                 scopes: ['selected'], scope_arguments: { selected: { id: 1 } })
    expect(registry.scope_owner(model_name: 'InheritanceDeliveryTruck', scope_name: 'selected')).to eq('InheritanceVehicle')
    expect(registry.get_scope_callable(model_name: 'InheritanceTruck', scope_name: 'selected')).to be_nil
    expect(registry.scopes_for(model_name: 'InheritanceDeliveryTruck')).to eq(['selected'])
    expect { registry.validate_references! }.not_to raise_error
  end

  it 'requires explicit child scope replacement without changing the parent definition' do
    inherit_rules
    parent = -> { InheritanceVehicle.all }
    child = -> { InheritanceTruck.all }
    registry.register_scope(model_name: 'InheritanceVehicle', scope_name: 'selected', &parent)
    expect { registry.register_scope(model_name: 'InheritanceTruck', scope_name: 'selected', &child) }
      .to raise_error(Writ::ConfigurationError, /replace: true/)
    registry.register_scope(model_name: 'InheritanceTruck', scope_name: 'selected', replace: true, &child)
    expect(registry.scope_owner(model_name: 'InheritanceDeliveryTruck', scope_name: 'selected')).to eq('InheritanceTruck')
    expect(registry.get_scope_callable(model_name: 'InheritanceVehicle', scope_name: 'selected')).to equal(parent)
    expect { registry.validate_references! }.not_to raise_error
  end

  it 'rejects implicit replacement even when inheritance is registered after scope declarations' do
    registry.register_scope(model_name: 'InheritanceVehicle', scope_name: 'selected') { InheritanceVehicle.all }
    registry.register_scope(model_name: 'InheritanceTruck', scope_name: 'selected') { InheritanceTruck.all }
    inherit_rules
    expect { registry.validate_references! }.to raise_error(Writ::ConfigurationError, /redefines an inherited scope/)
  end

  it 'applies default scopes ancestor-first and accepts an inherited tenant boundary' do
    inherit_rules
    registry.register_default_scope(model_name: 'InheritanceVehicle') { InheritanceVehicle.all }
    registry.register_default_scope(model_name: 'InheritanceTruck') { InheritanceTruck.all }
    registry.register_scope(model_name: 'InheritanceDeliveryTruck', scope_name: 'selected') { InheritanceDeliveryTruck.all }
    allow(Writ::Configuration).to receive(:multi_tenant?).and_return(true)
    expect(registry.default_scope_models(model_name: 'InheritanceDeliveryTruck')).to eq(%w[InheritanceVehicle InheritanceTruck])
    expect { registry.validate_references! }.not_to raise_error
  end

  it 'returns lifecycle validators global-first then ancestor-first, with optional global exclusion' do
    inherit_rules
    global = ->(context:, record:) { true }
    parent = ->(context:, record:) { true }
    child = ->(context:, record:) { true }
    [:creation, :update].each do |kind|
      registry.public_send("register_#{kind}_validator", &global)
      registry.public_send("register_#{kind}_validator", model_name: 'InheritanceVehicle', &parent)
      registry.public_send("register_#{kind}_validator", model_name: 'InheritanceTruck', &child)
      expect(registry.public_send("#{kind}_validators_for", model_name: 'InheritanceDeliveryTruck')).to eq([global, parent, child])
      expect(registry.public_send("#{kind}_validators_for", model_name: 'InheritanceDeliveryTruck', include_global: false)).to eq([parent, child])
      expect(registry.public_send("#{kind}_validators_for", model_name: 'InheritanceTruck', include_inherited: false)).to eq([global, child])
      expect(registry.public_send("#{kind}_validators_for", model_name: 'InheritanceTruck', include_global: false, include_inherited: false)).to eq([child])
    end
  end

  it 'attaches inherited scopes to their defining catalog row and retains stored attachment identity' do
    inherit_rules
    registry.register_scope(model_name: 'InheritanceVehicle', scope_name: 'selected', arguments: { id: { type: :integer } }) { |_context, _arguments| InheritanceVehicle.all }
    role = create(:role)
    permission = role.permissions.create!(model: 'InheritanceTruck', action: 'read', scopes: [{ selected: { id: 12 } }])
    attachment = permission.permission_scopes.first
    expect(attachment.scope.model).to eq('InheritanceVehicle')
    expect(attachment.arguments).to eq('id' => 12)

    registry.register_scope(model_name: 'InheritanceTruck', scope_name: 'selected', replace: true) { InheritanceTruck.all }
    expect(permission.reload.permission_scopes.first.scope.model).to eq('InheritanceVehicle')
    expect(permission).to be_valid
  end

  it 'rejects siblings and duplicate scope names from different defining models' do
    inherit_rules
    registry.register_scope(model_name: 'InheritanceVehicle', scope_name: 'selected') { InheritanceVehicle.all }
    registry.register_scope(model_name: 'InheritanceTruck', scope_name: 'selected', replace: true) { InheritanceTruck.all }
    permission = create(:role).permissions.create!(model: 'InheritanceTruck', action: 'read', scopes: ['selected'])
    parent_scope = Scope.create!(model: 'InheritanceVehicle', name: 'selected')
    duplicate = permission.permission_scopes.build(scope: parent_scope, arguments: {})
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:scope]).to include("name 'selected' is already attached to this permission")

    unrelated = permission.permission_scopes.build(scope: Scope.create!(model: 'InheritanceVan', name: 'other'), arguments: {})
    expect(unrelated).not_to be_valid
    expect(unrelated.errors[:scope].join).to include('does not match')
  end

  it 'generates one shared parent grant and attaches child grants to ancestor scope rows' do
    inherit_rules
    registry.register_scope(model_name: 'InheritanceVehicle', scope_name: 'selected') { InheritanceVehicle.all }
    registry.register_permission(model: 'InheritanceVehicle', role: 'Driver', action: :read, scopes: ['selected'])
    registry.register_permission(model: 'InheritanceTruck', role: 'Driver', action: :update, scopes: ['selected'])
    tenant = create(:organisation)
    Writ::Generator.generate_permissions(
      scoped_by_record: tenant,
      roles: [{ name: 'Driver' }],
      permissions_by_role: Writ::Generator.send(:build_permissions_by_role, registry)
    )
    grants = tenant.roles.find_by!(name: 'Driver').permissions
    expect(grants.order(:model).pluck(:model, :action)).to eq([
      ['InheritanceTruck', 'update'], ['InheritanceVehicle', 'read']
    ])
    expect(grants.flat_map(&:scope_records).map(&:model).uniq).to eq(['InheritanceVehicle'])
    expect(Writ::Generator.stale_items(registry).select { |item| item[:type] == :permission }).to be_empty
  end

  it 'distinguishes generated permissions pinned to different scope owners' do
    inherit_rules
    registry.register_scope(model_name: 'InheritanceVehicle', scope_name: 'selected') { InheritanceVehicle.all }
    permission = create(:role).permissions.create!(model: 'InheritanceTruck', action: 'read', scopes: ['selected'])
    config = { model: 'InheritanceTruck', action: 'read', scopes: ['selected'] }
    generator = Writ::Generator
    original_signature = generator.send(:permission_signature_from_record, permission)
    expect(generator.send(:permission_signature_from_config, config)).to eq(original_signature)

    registry.register_scope(model_name: 'InheritanceTruck', scope_name: 'selected', replace: true) { InheritanceTruck.all }
    expect(generator.send(:permission_signature_from_config, config)).not_to eq(original_signature)
  end
end
