# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Automatic STI proposed writes' do
  let(:config) { Writ::Configuration }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions, :roles).new(role.permissions, Role.where(id: role.id)) }
  let(:record) do
    asset = create(:asset, organisation: organisation, description: 'ProposalTruck')
    ProposalTruck.find(asset.id)
  end

  around do |example|
    registry = config.registry
    resolver = config.authorization_model_resolver
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    config.authorization_model_resolver = nil
    example.run
  ensure
    config.instance_variable_set(:@registry, registry)
    config.authorization_model_resolver = resolver
  end

  before do
    stub_const('ProposalVehicle', Class.new(ActiveRecord::Base) do
      self.table_name = 'assets'
      self.inheritance_column = 'description'
      belongs_to :location
    end)
    stub_const('ProposalTruck', Class.new(ProposalVehicle))
    stub_const('ProposalVan', Class.new(ProposalVehicle))
  end

  def grant(model = ProposalTruck, action = :update, scopes: [])
    create(:permission, role: role, model: model.name, action: action, scopes: scopes)
  end

  def propose(subject = record, **options)
    Writ::Access.propose(subject: subject, context: context, **options)
  end

  def grant_transition
    grant
    grant(ProposalVan)
  end

  it 'returns the same object for an ordinary update and leaves it unsaved' do
    grant
    original = record.name
    proposal = propose(attributes: { name: 'Changed' })
    expect(proposal.record).to equal(record)
    expect(proposal.result).to be_allowed
    expect(ProposalTruck.find(record.id).name).to eq(original)
  end

  it 'automatically casts a submitted discriminator and preserves the saved dirty baseline' do
    grant_transition
    original = record.name
    proposal = propose(attributes: { description: 'ProposalVan', name: 'Changed' })
    expect(proposal.result).to be_allowed
    expect(proposal.record).to be_a(ProposalVan)
    expect(proposal.record).to be_persisted
    expect(proposal.record.id).to eq(record.id)
    expect(proposal.record.changes_to_save).to include('description' => ['ProposalTruck', 'ProposalVan'], 'name' => [original, 'Changed'])
    expect(ProposalVehicle.find(record.id)).to be_a(ProposalTruck)
    proposal.record.name = 'Independent'
    expect(record.name).to eq(original)
    expect(record.description).to eq('ProposalTruck')
  end

  it 'saves through destination validations and callbacks without requiring create permission' do
    grant_transition
    ProposalVan.validates :name, presence: true
    ProposalVan.before_save { self.name = "Van: #{name}" }
    proposal = propose(attributes: { description: 'ProposalVan', name: '' })
    expect(proposal.result).to be_allowed
    expect { proposal.record.save! }.to raise_error(ActiveRecord::RecordInvalid)
    proposal.record.name = 'Delivery'
    proposal.record.save!
    saved = ProposalVehicle.find(record.id)
    expect(saved).to be_a(ProposalVan)
    expect(saved.name).to eq('Van: Delivery')
  end

  it 'uses dirty tracking when attributes are omitted' do
    grant_transition
    record.description = 'ProposalVan'
    proposal = propose
    expect(proposal.result).to be_allowed
    expect(proposal.record).to be_a(ProposalVan)
  end

  it 'checks an actual type transition even with an explicitly empty attributes hash' do
    grant_transition
    role.update!(accessible_fields: { 'ProposalTruck' => ['name'], 'ProposalVan' => ['name'] })
    record.description = 'ProposalVan'
    proposal = propose(attributes: {})
    expect(proposal.record).to be_a(ProposalVan)
    expect(proposal.result.reason).to eq(:forbidden_fields)
    expect(proposal.result.errors.map(&:attribute)).to eq([:description])
  end

  it 'requires source saved authority' do
    grant(ProposalVan)
    proposal = propose(attributes: { description: 'ProposalVan' })
    expect(proposal.record).to be_a(ProposalVan)
    expect(proposal.result.reason).to eq(:no_grants)
  end

  it 'requires destination update authority' do
    grant
    proposal = propose(attributes: { description: 'ProposalVan' })
    expect(proposal.result.reason).to eq(:no_grants)
  end

  it 'does not treat an absent source row as authorized' do
    grant_transition
    subject = record
    ProposalTruck.where(id: subject.id).delete_all
    expect(propose(subject, attributes: { description: 'ProposalVan' }).result).not_to be_allowed
  end

  it 'checks submitted fields against both source and destination field settings' do
    grant_transition
    role.update!(accessible_fields: {
      'ProposalTruck' => { 'update' => %w[description name] },
      'ProposalVan' => { 'update' => ['description'] }
    })
    proposal = propose(attributes: { description: 'ProposalVan', name: 'Forbidden' })
    expect(proposal.result.reason).to eq(:forbidden_fields)
    expect(proposal.result.errors.map(&:attribute)).to eq([:name])
  end

  it 'checks the source SQL scope against the saved row and destination validator against the proposal' do
    original = record.name
    config.register_scope(model_name: 'ProposalTruck', scope_name: 'original') { ProposalTruck.where(name: original) }
    config.register_scope(model_name: 'ProposalVan', scope_name: 'destination', matches: ->(_, candidate) { candidate.name == 'Delivery' }) { ProposalVan.all }
    grant(scopes: ['original'])
    grant(ProposalVan, scopes: ['destination'])
    proposal = propose(attributes: { description: 'ProposalVan', name: 'Delivery' })
    expect(proposal.result).to be_allowed
    expect(propose(proposal.record, attributes: { name: 'Rejected' }).result.reason).to eq(:proposed_scope_mismatch)
  end

  it 'rechecks original source authority when retrying a typed failed proposal' do
    grant_transition
    first = propose(attributes: { description: 'ProposalVan' })
    role.permissions.where(model: 'ProposalTruck').delete_all
    expect(propose(first.record, attributes: {}).result.reason).to eq(:no_grants)
  end

  it 'runs source and destination lifecycle validators with the typed proposal and original values' do
    grant_transition
    calls = []
    [ProposalTruck, ProposalVan].each do |model|
      config.register_update_validator(model_name: model.name) do |record:, **|
        calls << [model.name, record.class, record.attribute_in_database('description')]
        true
      end
    end
    expect(propose(attributes: { description: 'ProposalVan' }).result).to be_allowed
    expect(calls).to eq([
      ['ProposalTruck', ProposalVan, 'ProposalTruck'],
      ['ProposalVan', ProposalVan, 'ProposalTruck']
    ])
  end

  it 'deduplicates shared authorization-model lifecycle validators' do
    config.authorization_model_resolver = ->(model) { model.base_class }
    grant(ProposalVehicle)
    calls = 0
    config.register_update_validator(model_name: 'ProposalVehicle') { |**| calls += 1; true }
    expect(propose(attributes: { description: 'ProposalVan' }).result).to be_allowed
    expect(calls).to eq(1)
  end

  it 'constructs the final subtype before checking create authority' do
    grant(ProposalVan, :create)
    proposal = propose(ProposalTruck.new, attributes: { description: 'ProposalVan', name: 'New' })
    expect(proposal.record).to be_a(ProposalVan)
    expect(proposal.record).to be_new_record
    expect(proposal.result).to be_allowed
  end

  it 'does not substitute the original class create grant for the destination grant' do
    grant(ProposalTruck, :create)
    proposal = propose(ProposalTruck.new, attributes: { description: 'ProposalVan' })
    expect(proposal.result.reason).to eq(:no_grants)
  end

  it 'leaves correctly typed new records unchanged' do
    grant(ProposalTruck, :create)
    subject = ProposalTruck.new
    proposal = propose(subject, attributes: { name: 'New' })
    expect(proposal.record).to equal(subject)
    expect(proposal.result).to be_allowed
  end

  it 'supports changing a subtype back to the base through an empty discriminator' do
    grant
    grant(ProposalVehicle)
    proposal = propose(attributes: { description: nil })
    expect(proposal.record.class).to eq(ProposalVehicle)
    expect(proposal.result).to be_allowed
    proposal.record.save!
    expect(ProposalVehicle.find(record.id).class).to eq(ProposalVehicle)
  end

  it 'keeps the instance when a discriminator edit still resolves to the same base class' do
    grant(ProposalVehicle)
    asset = create(:asset, organisation: organisation, description: nil)
    subject = ProposalVehicle.find(asset.id)
    proposal = propose(subject, attributes: { description: '' })
    expect(proposal.record).to equal(subject)
    expect(proposal.result).to be_allowed
    expect(proposal.record.changes_to_save).to include('description' => [nil, ''])
  end

  it 'rejects unknown or unrelated discriminator values with a field error' do
    grant
    ['MissingVehicleType', 'User'].each do |type|
      proposal = propose(attributes: { description: type })
      expect(proposal.result.reason).to eq(:invalid_sti_type)
      expect(proposal.result.errors.map(&:attribute)).to eq([:description])
    end
  end

  it 'preserves readonly and strict-loading state and host errors without initialization callbacks' do
    grant_transition
    ProposalVan.after_initialize { raise 'must not initialize an already loaded proposal' }
    record.readonly!
    record.strict_loading!
    record.errors.add(:name, :invalid, message: 'host error')
    proposal = propose(attributes: { description: 'ProposalVan' })
    expect(proposal.result).to be_allowed
    expect(proposal.record).to be_readonly
    expect(proposal.record).to be_strict_loading
    expect(proposal.record.errors[:name]).to eq(['host error'])
    expect { proposal.record.save! }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it 'preserves owned error identity when copying a proposal so success clears only Writ errors' do
    grant_transition
    record.errors.add(:name, :invalid, message: 'host error')
    Writ::Access::CheckResult.new(allowed: false, reason: :forbidden_fields).apply_errors_to(record)
    proposal = propose(attributes: { description: 'ProposalVan' })
    proposal.result.apply_errors_to(proposal.record)
    expect(proposal.record.errors.full_messages).to eq(['Name host error'])
  end

  it 'rejects pending association writes before discarding cached associations' do
    grant_transition
    record.location.name = 'Pending association change'
    expect { propose(attributes: { description: 'ProposalVan' }) }.to raise_error(ArgumentError, /association changes/)
  end

  it 'rejects primary key changes and destroyed objects' do
    grant_transition
    expect { propose(attributes: { description: 'ProposalVan', id: record.id + 1 }) }.to raise_error(ArgumentError, /primary key/)
    record.restore_attributes
    record.reload.destroy!
    expect { propose(attributes: { description: 'ProposalVan' }) }.to raise_error(ArgumentError, /destroyed/)
  end

  it 'uses destination enum casting without inventing changes to saved attributes' do
    ProposalVan.enum :status, { available: 0, unavailable: 1 }
    grant_transition
    proposal = propose(attributes: { description: 'ProposalVan' })
    expect(proposal.result).to be_allowed
    expect(proposal.record.status).to eq('available')
    expect(proposal.record.attribute_in_database('status')).to eq('available')
    expect(proposal.record.changes_to_save.keys).to eq(['description'])
  end

  it 'assigns incoming attributes using destination setters and enum values' do
    ProposalTruck.enum :status, { active: 0, retired: 1 }
    ProposalVan.enum :status, { available: 0, unavailable: 1 }
    ProposalVan.class_eval do
      def name=(value)
        super("Van: #{value}")
      end
    end
    grant_transition
    proposal = propose(attributes: { description: 'ProposalVan', status: 'unavailable', name: 'Delivery' })
    expect(proposal.result).to be_allowed
    expect(proposal.record.name).to eq('Van: Delivery')
    expect(proposal.record.status).to eq('unavailable')
    expect(proposal.record.changes_to_save['status']).to eq(['available', 'unavailable'])
    expect(record.status).to eq('active')
    proposal.record.save!
    expect(ProposalVan.find(record.id).status).to eq('unavailable')
  end

  it 'retains source authority and destination enum values when retrying a typed proposal' do
    ProposalTruck.enum :status, { active: 0, retired: 1 }
    ProposalVan.enum :status, { available: 0, unavailable: 1 }
    grant_transition
    proposal = propose(attributes: { description: 'ProposalVan', status: 'unavailable' })
    expect(propose(proposal.record, attributes: {}).result).to be_allowed
    expect(proposal.record.status).to eq('unavailable')
  end

  it 'uses destination enum casting and create validators for a converted new record' do
    ProposalTruck.enum :status, { active: 0, retired: 1 }
    ProposalVan.enum :status, { available: 0, unavailable: 1 }
    grant(ProposalVan, :create)
    config.register_creation_validator(model_name: 'ProposalVan') { |record:, **| record.status == 'unavailable' }
    proposal = propose(ProposalTruck.new, attributes: { description: 'ProposalVan', status: 'unavailable' })
    expect(proposal.result).to be_allowed
    expect(proposal.record).to be_a(ProposalVan)
    expect(proposal.record).to be_new_record
  end

  it 'isolates nested serialized state while preserving its dirty baseline' do
    if ActiveRecord.gem_version >= Gem::Version.new('7.1')
      ProposalVehicle.serialize :name, coder: JSON
    else
      ProposalVehicle.serialize :name, JSON
    end
    grant_transition
    row = create(:asset, organisation: organisation, description: 'ProposalTruck', name: '[{"label":"Original"}]')
    subject = ProposalTruck.find(row.id)
    subject.name.first['label'] = 'Pending'
    subject.description = 'ProposalVan'
    proposal = propose(subject)
    expect(proposal.result).to be_allowed
    expect(proposal.record.attribute_in_database('name')).to eq([{ 'label' => 'Original' }])
    expect(proposal.record.name).to eq([{ 'label' => 'Pending' }])
    proposal.record.name.first['label'] = 'Independent'
    expect(subject.name).to eq([{ 'label' => 'Pending' }])
  end

  it 'rejects a setter that changes the final discriminator after the destination was selected' do
    ProposalVan.class_eval do
      def name=(value)
        super
        self.description = 'ProposalTruck'
      end
    end
    grant_transition
    proposal = propose(attributes: { description: 'ProposalVan', name: 'Changed by setter' })
    expect(proposal.record).to be_a(ProposalVan)
    expect(proposal.result.reason).to eq(:invalid_sti_type)
    expect(proposal.result.errors.map(&:attribute)).to eq([:description])
  end

  it 'recasts dirty attributes and retains their saved baseline when attributes are omitted' do
    ProposalVan.attribute :status, :string
    grant_transition
    record.status = 1
    record.description = 'ProposalVan'
    proposal = propose
    expect(proposal.result).to be_allowed
    expect(proposal.record.status).to eq('1')
    expect(proposal.record.changes_to_save['status']).to eq(['0', '1'])
  end

  it 'preserves target virtual attributes without loading defaults for omitted database columns' do
    ProposalVan.attribute :delivery_note, :string
    grant_transition
    proposal = propose(attributes: { description: 'ProposalVan', delivery_note: 'Handle carefully' })
    expect(proposal.result).to be_allowed
    expect(proposal.record.delivery_note).to eq('Handle carefully')
  end

  it 'uses an inheritance-column alias and checks its canonical field permission' do
    ProposalVehicle.alias_attribute :kind, :description
    grant_transition
    proposal = propose(attributes: { kind: 'ProposalVan' })
    expect(proposal.record).to be_a(ProposalVan)
    expect(proposal.result).to be_allowed

    role.update!(accessible_fields: { 'ProposalTruck' => ['name'] })
    expect(propose(attributes: { kind: 'ProposalVan' }).result.reason).to eq(:forbidden_fields)
  end

  it 'rejects unpermitted Parameters before constructing or mutating a proposal' do
    grant_transition
    original = record.attributes
    attributes = ActionController::Parameters.new(description: 'ProposalVan', name: 'Rejected')
    expect { propose(attributes: attributes) }.to raise_error(ActiveModel::ForbiddenAttributesError)
    expect(record.attributes).to eq(original)
  end

  it 'preserves optimistic locking when saving the converted record' do
    [ProposalVehicle, ProposalTruck, ProposalVan].each { |model| model.locking_column = 'status' }
    grant_transition
    proposal = propose(attributes: { description: 'ProposalVan' })
    expect(proposal.record.locking_enabled?).to be_truthy
    ProposalTruck.where(id: record.id).update_all(status: 1)
    expect { proposal.record.save! }.to raise_error(ActiveRecord::StaleObjectError)
    expect(ProposalVehicle.find(record.id)).to be_a(ProposalTruck)
  end

  it 'uses Rails STI resolution for namespaced short discriminator names' do
    stub_const('ProposalFleet', Module.new)
    stub_const('ProposalFleet::Vehicle', Class.new(ActiveRecord::Base) do
      self.table_name = 'assets'
      self.inheritance_column = 'description'
      self.store_full_sti_class = false
    end)
    stub_const('ProposalFleet::Truck', Class.new(ProposalFleet::Vehicle))
    stub_const('ProposalFleet::Van', Class.new(ProposalFleet::Vehicle))
    grant(ProposalFleet::Truck)
    grant(ProposalFleet::Van)
    row = create(:asset, organisation: organisation, description: 'Truck')
    subject = ProposalFleet::Truck.find(row.id)
    proposal = propose(subject, attributes: { description: 'Van' })
    expect(proposal.result).to be_allowed
    expect(proposal.record).to be_a(ProposalFleet::Van)
    expect(proposal.record.description).to eq(ProposalFleet::Van.sti_name)
  end

  it 'returns the typed record from the Pundit helper and uses its existing proposed error format' do
    grant_transition
    controller = Class.new(ActionController::Base) do
      include Pundit::Authorization
      attr_accessor :actor
      def pundit_user = actor
    end.new
    controller.actor = context
    role.update!(accessible_fields: { 'ProposalTruck' => ['name'], 'ProposalVan' => ['name'] })
    error = nil
    expect { controller.send(:authorize_proposed!, record, attributes: { description: 'ProposalVan' }) }
      .to raise_error(Writ::Pundit::ProposedAuthorizationError) { |caught| error = caught }
    expect(error.record).to be_a(ProposalVan)
    expect(error.query).to eq(:update?)
    expect(error.record.errors.of_kind?(:description, :not_permitted)).to be(true)

    role.update!(accessible_fields: { 'ProposalTruck' => nil, 'ProposalVan' => nil })
    returned = controller.send(:authorize_proposed!, error.record, attributes: {})
    expect(returned).to equal(error.record)
    expect(returned.errors).to be_empty
    expect { controller.send(:verify_authorized) }.to raise_error(Pundit::AuthorizationNotPerformedError)
  end

  it 'reports an invalid type as a proposed field error through Pundit' do
    grant
    controller = Class.new(ActionController::Base) do
      include Pundit::Authorization
      attr_accessor :actor
      def pundit_user = actor
    end.new
    controller.actor = context
    expect { controller.send(:authorize_proposed!, record, attributes: { description: 'User' }) }
      .to raise_error(Writ::Pundit::ProposedAuthorizationError) { |error|
        expect(error.result.reason).to eq(:invalid_sti_type)
        expect(error.record.errors.of_kind?(:description, :invalid)).to be(true)
      }
  end

  it 'does not interpret ordinary attributes as STI when the inheritance column is disabled' do
    ProposalVehicle.inheritance_column = '_disabled_type'
    grant
    subject = ProposalTruck.new(name: 'New', description: 'Unrelated')
    grant(ProposalTruck, :create)
    proposal = propose(subject, attributes: { description: 'User' })
    expect(proposal.record).to equal(subject)
    expect(proposal.result).to be_allowed
  end
end
