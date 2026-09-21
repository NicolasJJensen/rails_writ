require 'rails_helper'

RSpec.describe 'CRUD field shorthand' do
  let(:config) { Writ::Configuration }
  let(:access) { Writ::Access }
  let(:actions) { %w[create read update delete] }

  around do |example|
    registry = config.registry
    field_default = config.field_default
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    config.field_default = []
    example.run
  ensure
    config.instance_variable_set(:@registry, registry)
    config.field_default = field_default
    Current.reset
  end

  def define_fields(fields, action: nil)
    config.configure { accessible_fields fields, model: Asset, role: :Reviewer, action: action }
  end

  def stored
    config.registry.all_accessible_fields.fetch('Reviewer').fetch('Asset')
  end

  it 'expands the shorthand into exactly four independently overridable CRUD entries' do
    define_fields([:name])
    expect(stored).to eq(actions.to_h { |action| [action, ['name']] })
    define_fields([:description], action: :read)
    expect(stored).to eq('create' => ['name'], 'read' => ['description'], 'update' => ['name'], 'delete' => ['name'])
  end

  it 'can narrow an earlier action declaration rather than retaining removed fields' do
    define_fields([:name, :description], action: :read)
    define_fields([:name], action: :read)
    expect(stored).to eq('read' => ['name'])
  end

  it 'applies a later shorthand to CRUD only, preserving custom action declarations' do
    define_fields([:description], action: :approve)
    define_fields([:description], action: :read)
    define_fields([:name])
    expect(stored).to eq(actions.to_h { |action| [action, ['name']] }.merge('approve' => ['description']))
  end

  it 'allows an empty or unrestricted override without changing sibling actions' do
    define_fields(:all)
    expect(stored).to eq(actions.to_h { |action| [action, nil] })
    define_fields([], action: :update)
    expect(stored['update']).to eq([])
    expect(stored.values_at('create', 'read', 'delete')).to eq([nil, nil, nil])
    define_fields([])
    define_fields(:all, action: :read)
    expect(stored).to eq('create' => [], 'read' => nil, 'update' => [], 'delete' => [])
  end

  it 'does not retain mutable caller field names' do
    fields = ['name']
    define_fields(fields)
    fields.first.replace('description')
    fields << 'status'
    expect(stored).to eq(actions.to_h { |action| [action, ['name']] })
  end

  it 'rejects an invalid action without changing valid definitions' do
    define_fields([:name])
    before = stored
    expect { define_fields(:all, action: 'bad action') }.to raise_error(ArgumentError)
    expect(stored).to eq(before)
  end

  it 'persists policy shorthand and keeps read overrides out of writable fields' do
    stub_const('FieldShorthandPolicy', Class.new do
      include Writ::PolicyHelpers
      def self.policy_model
        Asset
      end
    end)
    FieldShorthandPolicy.role(:Reviewer) do
      %i[create read update delete approve].each { |action| permission action }
      accessible_fields [:name]
      accessible_fields [:name, :description], action: :read
    end
    organisation = create(:organisation)
    role = organisation.roles.find_by!(name: 'Reviewer')
    actor = Struct.new(:permissions).new(role.permissions)
    asset = create(:asset, organisation: organisation)
    expect(role.accessible_fields['Asset']).to eq('create' => ['name'], 'read' => %w[name description], 'update' => ['name'], 'delete' => ['name'])
    expect(access.readable_fields(context: actor, record: asset)).to eq(%w[name description])
    expect(access.writable_fields(context: actor, record: asset)).to eq(['name'])
    expect(access.fields_for(context: actor, action: :delete, record: asset)).to eq(['name'])
    expect(access.fields_for(context: actor, action: :approve, record: asset)).to eq([])
    expect(access.fields_for(context: actor, action: :create, record: Asset)).to eq(['name'])
  end

  it 'keeps existing database array restrictions intact during an explicit permission migration' do
    define_fields([:description])
    config.configure { permission :approve, model: Asset, role: :Reviewer }
    organisation = create(:organisation)
    role = organisation.roles.find_by!(name: 'Reviewer')
    role.permissions.destroy_all
    role.update!(accessible_fields: { 'Asset' => ['name'] })
    Writ::Generator.add_permissions(organisation, permissions: [{ model: Asset, action: :approve }])
    actor = Struct.new(:permissions).new(role.permissions)
    expect(access.fields_for(context: actor, action: :approve, record: Asset)).to eq(['name'])
    expect(role.reload.accessible_fields['Asset']).to eq(['name'])
  end
end
