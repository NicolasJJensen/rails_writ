# frozen_string_literal: true

require 'rails_helper'
require 'open3'

RSpec.describe 'Pundit proposed authorization' do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:role) { create(:role, organisation: organisation, accessible_fields: { 'Asset' => ['name'] }) }
  let(:record) { create(:asset, organisation: organisation) }
  let(:controller) do
    Class.new(ActionController::Base) do
      include Pundit::Authorization
      attr_accessor :actor
      def pundit_user = actor
    end.new.tap { |instance| instance.actor = user }
  end

  around do |example|
    original = Writ::Configuration.registry
    Writ::Configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    user.roles << role
    example.run
  ensure
    Writ::Configuration.instance_variable_set(:@registry, original)
  end

  def grant(action = :update, **options)
    create(:permission, role: role, action: action, **options)
  end

  it 'uses dirty fields when attributes are omitted and never saves' do
    grant
    previous = record.name
    record.name = 'Pending'
    expect(controller.send(:authorize_proposed!, record)).to equal(record)
    expect(record.name).to eq('Pending')
    expect(Asset.find(record.id).name).to eq(previous)
  end

  it 'rejects a dirty forbidden attribute and attaches structured errors to the same record' do
    grant
    record.status = :maintenance_required
    expect { controller.send(:authorize_proposed!, record) }.to raise_error(Writ::Pundit::ProposedAuthorizationError) { |error|
      expect(error).to be_a(Pundit::NotAuthorizedError)
      expect(error.record).to equal(record)
      expect(error.result.reason).to eq(:forbidden_fields)
      expect(error.query).to eq(:update?)
    }
    expect(record.errors.of_kind?(:status, :not_permitted)).to be(true)
  end

  it 'checks explicitly submitted unchanged keys and distinguishes an empty submission from omitted attributes' do
    grant
    expect { controller.send(:authorize_proposed!, record, attributes: { status: record.status }) }
      .to raise_error(Writ::Pundit::ProposedAuthorizationError)
    record.status = :maintenance_required
    expect(controller.send(:authorize_proposed!, record, attributes: {})).to equal(record)
    expect(record.errors).to be_empty
    expect { controller.send(:authorize_proposed!, record) }.to raise_error(Writ::Pundit::ProposedAuthorizationError)
  end

  it 'assigns permitted Parameters and rejects unpermitted Parameters before assignment' do
    grant
    permitted = ActionController::Parameters.new(name: 'Accepted').permit(:name)
    expect(controller.send(:authorize_proposed!, record, attributes: permitted).name).to eq('Accepted')
    expect { controller.send(:authorize_proposed!, record, attributes: ActionController::Parameters.new(name: 'Rejected')) }
      .to raise_error(ActiveModel::ForbiddenAttributesError)
    expect(record.name).to eq('Accepted')
  end

  it 'accepts standard Rails date-select parameters for an allowed date field' do
    role.update!(accessible_fields: { 'Asset' => ['purchase_date'] })
    grant
    controller.params = { asset: { 'purchase_date(1i)' => '2026', 'purchase_date(2i)' => '10', 'purchase_date(3i)' => '1' } }
    input = controller.send(:permitted_attributes, record, :update)
    controller.send(:authorize_proposed!, record, attributes: input)
    expect(record.purchase_date).to eq(Date.new(2026, 10, 1))
  end

  it 'still rejects explicitly submitted unchanged multiparameter fields when the date is forbidden' do
    grant
    record.update!(purchase_date: Date.new(2026, 10, 1))
    input = { 'purchase_date(1i)' => '2026', 'purchase_date(2i)' => '10', 'purchase_date(3i)' => '1' }
    expect { controller.send(:authorize_proposed!, record, attributes: input) }
      .to raise_error(Writ::Pundit::ProposedAuthorizationError)
    expect(record.errors.of_kind?(:purchase_date, :not_permitted)).to be(true)
    expect(record).not_to be_changed
  end

  it 'compares submitted and allowed attribute aliases using the canonical model attribute' do
    stub_const('AliasedAsset', Class.new(Asset) { alias_attribute :title, :name })
    aliased = AliasedAsset.find(record.id)
    create(:permission, role: role, action: :update, model: 'AliasedAsset')
    role.update!(accessible_fields: { 'AliasedAsset' => ['name'] })
    controller.send(:authorize_proposed!, aliased, attributes: { title: 'Through alias' })
    expect(aliased.name).to eq('Through alias')

    role.update!(accessible_fields: { 'AliasedAsset' => ['title'] })
    controller.send(:authorize_proposed!, aliased, attributes: { name: 'Through canonical name' })
    expect(aliased.title).to eq('Through canonical name')

    role.update!(accessible_fields: { 'AliasedAsset' => [] })
    expect { controller.send(:authorize_proposed!, aliased, attributes: { title: aliased.name }) }
      .to raise_error(Writ::Pundit::ProposedAuthorizationError)
    expect(aliased.errors.of_kind?(:name, :not_permitted)).to be(true)
  end

  it 'infers create for a new record and accepts an explicit action' do
    grant(:create)
    candidate = Asset.new
    expect(controller.send(:authorize_proposed!, candidate, attributes: { name: 'New' })).to equal(candidate)
    grant(:publish)
    expect(controller.send(:authorize_proposed!, record, action: :publish, attributes: {})).to equal(record)
  end

  it 'leaves normal Pundit authorization verification separate' do
    grant
    controller.send(:authorize_proposed!, record, attributes: {})
    expect { controller.send(:verify_authorized) }.to raise_error(Pundit::AuthorizationNotPerformedError)
    controller.send(:authorize, record, :update?)
    expect { controller.send(:verify_authorized) }.not_to raise_error
  end

  it 'keeps missing authority as a normal Pundit denial' do
    expect { controller.send(:authorize_proposed!, record, attributes: {}) }.to raise_error(Pundit::NotAuthorizedError) { |error|
      expect(error).not_to be_a(Writ::Pundit::ProposedAuthorizationError)
      expect(error.record).to equal(record)
    }
  end

  it 'keeps condition failures as normal Pundit denials' do
    Writ::Configuration.register_condition(name: 'blocked') { false }
    grant(conditions: ['blocked'])
    expect { controller.send(:authorize_proposed!, record, attributes: {}) }.to raise_error(Pundit::NotAuthorizedError) { |error|
      expect(error).not_to be_a(Writ::Pundit::ProposedAuthorizationError)
    }
  end

  it 'propagates proposed scope errors and clears only Writ errors after a successful retry' do
    Writ::DSL::ConfigurationDSL.new(Writ::Configuration).scope(:named, model: Asset) do
      query { Asset.all }
      validate do |candidate, errors|
        errors.add(:name, :invalid, message: 'must start with A') unless candidate.name.start_with?('A')
      end
    end
    grant(scopes: ['named'])
    record.errors.add(:name, :invalid, message: 'host error')
    expect { controller.send(:authorize_proposed!, record, attributes: { name: 'Bad' }) }
      .to raise_error(Writ::Pundit::ProposedAuthorizationError) { |error|
        expect(error.result.reason).to eq(:proposed_scope_mismatch)
      }
    expect(record.errors[:name]).to contain_exactly('host error', 'must start with A')
    controller.send(:authorize_proposed!, record, attributes: { name: 'Allowed' })
    expect(record.errors[:name]).to eq(['host error'])
  end

  it 'preserves application exceptions from validators' do
    Writ::Configuration.register_update_validator(model_name: 'Asset') { |**| raise 'host validator failed' }
    grant
    expect { controller.send(:authorize_proposed!, record, attributes: {}) }.to raise_error(RuntimeError, 'host validator failed')
  end

  it 'works on ActionController::API as well as Base' do
    api = Class.new(ActionController::API) { include Pundit::Authorization }.new
    expect(api.respond_to?(:authorize_proposed!, true)).to be(true)
    expect(api.class.action_methods).not_to include("authorize_proposed!")
  end

  it 'reaches controllers that include Pundit before or after loading the adapter' do
    script = <<~'CODE'
      require 'logger'
      require 'action_controller/railtie'
      require 'pundit'
      class Earlier < ActionController::Base
        include Pundit::Authorization
      end
      class EarlierApi < ActionController::API
        include Pundit::Authorization
      end
      require 'rails_writ/pundit'
      class Later < ActionController::Base
        include Pundit::Authorization
      end
      raise 'missing helper' unless [Earlier, EarlierApi, Later].all? { |type| type.new.respond_to?(:authorize_proposed!, true) }
    CODE
    output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-Igems/rails_writ-pundit/lib', '-e', script)
    expect(status.success?).to be(true), output
  end
end
