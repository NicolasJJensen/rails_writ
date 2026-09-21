require 'rails_helper'
require 'rake'

RSpec.describe 'Rake generation with custom host keys' do
  before do
    load File.expand_path('../../../../lib/tasks/writ.rake', __dir__) unless Rake::Task.task_defined?('writ:generate')
    Rake::Task.define_task(:environment)
  end

  it 'finds a tenant through its configured primary key' do
    stub_const('CustomKeyTenant', Class.new(ActiveRecord::Base) do
      self.table_name = 'organisations'
      self.primary_key = 'abn'
      has_many :roles, class_name: 'Role', foreign_key: :organisation_id, primary_key: :id
    end)
    tenant = create(:organisation)
    tenant.update!(abn: "ABN-#{tenant.id}")

    generated = false
    allow(Writ::Generator).to receive(:generate_default_permissions) { generated = true }
    allow_any_instance_of(Object).to receive(:abort) { throw :generation_aborted }

    original = ENV.to_h.slice('ID', 'ORG', 'MODEL', 'MODELS')
    ENV['ID'] = tenant.abn
    ENV['MODEL'] = 'CustomKeyTenant'
    ENV.delete('ORG')
    ENV.delete('MODELS')
    expect(ENV['ID']).to eq(tenant.abn)

    Rake::Task['writ:generate'].reenable
    catch(:generation_aborted) { Rake::Task['writ:generate'].invoke }
    expect(generated).to be(true)
  ensure
    %w[ID ORG MODEL MODELS].each { |key| ENV.delete(key) }
    original&.each { |key, value| ENV[key] = value }
  end

  it 'rejects a roleable actor model before generating in multi-tenant mode' do
    organisation = create(:organisation)
    actor = create(:user, organisation: organisation)
    original_multi_tenant = Writ::Configuration.multi_tenant
    original_scoping_model = Writ::Configuration.default_scoping_model
    Writ::Configuration.multi_tenant = true
    Writ::Configuration.default_scoping_model = 'Organisation'

    allow(Writ::Generator).to receive(:generate_default_permissions)
    allow_any_instance_of(Object).to receive(:abort) { |*args| raise ArgumentError, args.last.to_s }

    original = ENV.to_h.slice('ID', 'ORG', 'MODEL', 'MODELS')
    ENV['ID'] = actor.id.to_s
    ENV['MODEL'] = 'User'
    ENV.delete('ORG')
    ENV.delete('MODELS')

    Rake::Task['writ:generate'].reenable
    expect { Rake::Task['writ:generate'].invoke }
      .to raise_error(ArgumentError, /Organisation.*tenant|configured.*scoping model/i)
    expect(Writ::Generator).not_to have_received(:generate_default_permissions)
  ensure
    Writ::Configuration.multi_tenant = original_multi_tenant
    Writ::Configuration.default_scoping_model = original_scoping_model
    %w[ID ORG MODEL MODELS].each { |key| ENV.delete(key) }
    original&.each { |key, value| ENV[key] = value }
  end

  it 'still generates for the configured tenant model in multi-tenant mode' do
    organisation = create(:organisation)
    original_multi_tenant = Writ::Configuration.multi_tenant
    original_scoping_model = Writ::Configuration.default_scoping_model
    Writ::Configuration.multi_tenant = true
    Writ::Configuration.default_scoping_model = 'Organisation'

    expect(Writ::Generator).to receive(:generate_default_permissions).with(organisation, models: nil)

    original = ENV.to_h.slice('ID', 'ORG', 'MODEL', 'MODELS')
    ENV['ID'] = organisation.id.to_s
    ENV['MODEL'] = 'Organisation'
    ENV.delete('ORG')
    ENV.delete('MODELS')

    Rake::Task['writ:generate'].reenable
    Rake::Task['writ:generate'].invoke
  ensure
    Writ::Configuration.multi_tenant = original_multi_tenant
    Writ::Configuration.default_scoping_model = original_scoping_model
    %w[ID ORG MODEL MODELS].each { |key| ENV.delete(key) }
    original&.each { |key, value| ENV[key] = value }
  end

  it 'accepts an explicitly supplied scoping model when no default is configured' do
    organisation = create(:organisation)
    original_multi_tenant = Writ::Configuration.multi_tenant
    original_scoping_model = Writ::Configuration.default_scoping_model
    Writ::Configuration.multi_tenant = true
    Writ::Configuration.default_scoping_model = nil

    expect(Writ::Generator).to receive(:generate_default_permissions).with(organisation, models: nil)

    original = ENV.to_h.slice('ID', 'ORG', 'MODEL', 'MODELS')
    ENV['ID'] = organisation.id.to_s
    ENV['MODEL'] = 'Organisation'
    ENV.delete('ORG')
    ENV.delete('MODELS')

    Rake::Task['writ:generate'].reenable
    Rake::Task['writ:generate'].invoke
  ensure
    Writ::Configuration.multi_tenant = original_multi_tenant
    Writ::Configuration.default_scoping_model = original_scoping_model
    %w[ID ORG MODEL MODELS].each { |key| ENV.delete(key) }
    original&.each { |key, value| ENV[key] = value }
  end
end
