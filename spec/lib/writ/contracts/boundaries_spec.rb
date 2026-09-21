require 'rails_helper'
require 'rake'

RSpec.describe 'Permission boundary regressions' do
  let(:config) { Writ::Configuration }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions).new(role.permissions) }
  let!(:asset) { create(:asset, organisation: organisation) }
  before { Current.user = build(:user, organisation: organisation) }
  after { Current.reset }

  it 'preserves existence requirements in a default scope' do
    old = config.get_default_scope(model_name: 'Asset')
    config.register_default_scope(model_name: 'Asset', replace: true) { Asset.joins(:service_industries) }
    create(:permission, role: role)
    expect(Writ::Access.filter(context: context, action: :read, records: Asset)).to be_empty
  ensure
    config.remove_default_scope(model_name: 'Asset')
    config.register_default_scope(model_name: 'Asset', replace: true, &old) if old
  end

  it 'does not duplicate authorized records when multiple joined rows match' do
    config.register_scope(model_name: 'Asset', scope_name: 'many_contract') { Asset.joins(:service_industries) }
    asset.service_industries << create_list(:service_industry, 2, organisation: organisation)
    create(:permission, role: role, scopes: ['many_contract'])
    expect(Writ::Access.filter(context: context, action: :read, records: Asset).pluck(:id)).to eq([asset.id])
  ensure
    config.remove_scope_callable(model_name: 'Asset', scope_name: 'many_contract')
  end

  it 'preserves scope assignments across an outer transaction rollback and retry' do
    permission = create(:permission, role: role)
    Permission.transaction(requires_new: true) do
      permission.update!(scopes: ['status_active'])
      raise ActiveRecord::Rollback
    end
    permission.save!
    expect(permission.reload.scopes).to eq(['status_active'])
  end

  it 'cleans obsolete generated grants while retaining the custom grant on the same role' do
    role = organisation.roles.find_by!(name: 'Admin')
    generated = role.permissions.create!(model: 'Asset', action: 'export')
    generated.update_column(:generated_signature, Writ::Generator.signature_for(generated))
    custom = role.permissions.create!(model: 'Asset', action: 'approve')
    load File.expand_path('../../../../lib/tasks/writ.rake', __dir__) unless Rake::Task.task_defined?('writ:cleanup')
    Rake::Task.define_task(:environment)
    original = ENV['CONFIRM']
    ENV['CONFIRM'] = '1'
    Rake::Task['writ:cleanup'].reenable
    Rake::Task['writ:cleanup'].invoke
    expect(Permission.exists?(generated.id)).to be(false)
    expect(Permission.exists?(custom.id)).to be(true)
  ensure
    ENV['CONFIRM'] = original
  end

  it 'exposes cleanup as a reusable domain operation' do
    role = organisation.roles.find_by!(name: 'Admin')
    generated = role.permissions.create!(model: 'Asset', action: 'export')
    generated.update_column(:generated_signature, Writ::Generator.signature_for(generated))
    custom = role.permissions.create!(model: 'Asset', action: 'approve')

    Writ::Generator.cleanup!(registry: Writ::Configuration.registry)

    expect(Permission.exists?(generated.id)).to be(false)
    expect(Permission.exists?(custom.id)).to be(true)
  end

  it 'rolls back earlier cleanup deletions when a later deletion fails' do
    role = organisation.roles.find_by!(name: 'Admin')
    first = role.permissions.create!(model: 'Asset', action: 'export')
    first.update_column(:generated_signature, Writ::Generator.signature_for(first))
    second = role.permissions.create!(model: 'Asset', action: 'publish')
    second.update_column(:generated_signature, Writ::Generator.signature_for(second))
    stale_items = [first, second].map do |permission|
      { type: :permission, record: permission, role_name: role.name, label: permission.action }
    end
    allow(second).to receive(:destroy!).and_raise(StandardError, 'cleanup failure')

    expect {
      Writ::Generator.cleanup!(
        registry: Writ::Configuration.registry,
        stale_items: stale_items
      )
    }.to raise_error(StandardError, 'cleanup failure')

    expect(Permission.exists?(first.id)).to be(true)
    expect(Permission.exists?(second.id)).to be(true)
  end

  it 'keeps catalog scopes referenced by custom permissions' do
    config.register_scope(model_name: 'Asset', scope_name: 'obsolete_scope_contract') { Asset.none }
    permission = create(:permission, role: role, scopes: ['obsolete_scope_contract'])
    config.remove_scope_callable(model_name: 'Asset', scope_name: 'obsolete_scope_contract')
    load File.expand_path('../../../../lib/tasks/writ.rake', __dir__) unless Rake::Task.task_defined?('writ:cleanup')
    Rake::Task.define_task(:environment)
    original = ENV['CONFIRM']
    ENV['CONFIRM'] = '1'
    Rake::Task['writ:cleanup'].reenable
    Rake::Task['writ:cleanup'].invoke
    expect(permission.reload.scopes).to eq(['obsolete_scope_contract'])
  ensure
    ENV['CONFIRM'] = original
  end

  it 'rejects composite keys explicitly' do
    stub_const('CompositeContract', Class.new(ActiveRecord::Base) { self.table_name = 'assets'; self.primary_key = ['id', 'organisation_id'] })
    expect { Writ::Access.filter(context: context, action: :read, records: CompositeContract) }.to raise_error(ArgumentError, /single-column/)
  end
end
