# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Pundit permitted attributes' do
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

  it 'uses standard Pundit parameter lookup and filtering' do
    create(:permission, role: role, action: :update)
    controller.params = { asset: { name: 'Permitted', status: 'maintenance_required' } }
    filtered = controller.send(:permitted_attributes, record, :update)
    expect(filtered).to be_permitted
    expect(filtered.to_h).to eq('name' => 'Permitted')
  end

  it 'retains host pundit_params_for overrides for alternate payload shapes' do
    create(:permission, role: role, action: :update)
    controller.define_singleton_method(:pundit_params_for) { |_record| params.require(:data).require(:attributes) }
    controller.params = { data: { attributes: { name: 'JSON API', status: 'maintenance_required' } } }
    expect(controller.send(:permitted_attributes, record, :update).to_h).to eq('name' => 'JSON API')
  end

  it 'retains host policy overrides for nested parameter schemas' do
    policy = Class.new(Writ::Pundit::Policy) do
      def permitted_attributes_for_update
        [:name, { service_industries: [:name] }]
      end
    end.new(user, record)
    allow(controller).to receive(:policy).with(record).and_return(policy)
    controller.params = { asset: { name: 'Nested', service_industries: [{ name: 'Allowed', secret: 'Dropped' }] } }
    expect(controller.send(:permitted_attributes, record, :update).to_h)
      .to eq('name' => 'Nested', 'service_industries' => [{ 'name' => 'Allowed' }])
  end

  it 'expands all fields only to actual model attributes and never permits arbitrary nested data' do
    role.update!(accessible_fields: { 'Asset' => nil })
    create(:permission, role: role, action: :update)
    expect(AssetPolicy.new(user, record).permitted_attributes_for_update).to match_array(Asset.attribute_names.map(&:to_sym))
    controller.params = { asset: { name: 'Allowed', arbitrary: 'Dropped', organisation: { name: 'Dropped' } } }
    expect(controller.send(:permitted_attributes, record, :update).to_h).to eq('name' => 'Allowed')
  end

  it 'resolves candidate create fields before assignment without calling proposed matchers or creation validators' do
    Writ::Configuration.register_scope(model_name: 'Asset', scope_name: 'needs_name', matches: ->(*) { raise 'matcher called' }) { Asset.all }
    Writ::Configuration.register_creation_validator(model_name: 'Asset') { |**| raise 'validator called' }
    create(:permission, role: role, action: :create, scopes: ['needs_name'])
    expect(AssetPolicy.new(user, Asset.new).permitted_attributes_for_create).to eq([:name])
    expect(AssetPolicy.new(user, Asset).permitted_attributes_for_create).to eq([:name])
  end

  it 'rejects fields from roles whose grant conditions fail' do
    Writ::Configuration.register_condition(name: 'blocked') { false }
    create(:permission, role: role, action: :create, conditions: ['blocked'])
    expect(AssetPolicy.new(user, Asset.new).permitted_attributes_for_create).to eq([])
  end

  it 'uses saved-state role field eligibility even after pending changes' do
    Writ::Configuration.register_scope(model_name: 'Asset', scope_name: 'original') { Asset.where(name: 'Original') }
    create(:permission, role: role, action: :update, scopes: ['original'])
    record.update!(name: 'Original')
    record.name = 'Pending'
    expect(AssetPolicy.new(user, record).permitted_attributes_for_update).to eq([:name])
  end
end
