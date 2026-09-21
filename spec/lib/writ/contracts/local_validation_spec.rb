# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Local matcher validation' do
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:user) { create(:user, organisation: organisation) }

  around do |example|
    original = Writ::Configuration.registry
    Writ::Configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    user.roles << role
    example.run
  ensure
    Writ::Configuration.instance_variable_set(:@registry, original)
    Writ::Configuration.on_missing_matcher = :raise
  end

  it 'warns for each missing matcher and still evaluates registered matchers' do
    Writ::Configuration.register_scope(model_name: 'Role', scope_name: 'missing') { Role.all }
    Writ::Configuration.register_scope(
      model_name: 'Role', scope_name: 'reject',
      matches: ->(_context, _record) { false }
    ) { Role.all }
    create(:permission, role: role, model: 'Role', action: 'read', scopes: %w[missing reject])
    Writ::Configuration.on_missing_matcher = :warning

    expect(Writ::Configuration.logger).to receive(:warn).with(/matches: matcher.*Role\/missing/i)
    decision = Writ::Access.validation(subject: create(:role, organisation: organisation), action: :read, context: user)

    expect(decision).not_to be_allowed
    expect(decision.reason).to eq(:proposed_scope_mismatch)
  end

  it 'rejects every invalid local collection member before it evaluates a record' do
    candidate = create(:role, organisation: organisation)

    expect {
      Writ::Access.validation(subject: [candidate, Object.new], action: :read, context: user)
    }.to raise_error(ArgumentError, /record/i)
  end

  it 'rejects a persisted record for local create validation' do
    create(:permission, role: role, model: 'Role', action: 'create')

    expect {
      Writ::Access.validation(subject: create(:role, organisation: organisation), action: :create, context: user)
    }.to raise_error(ArgumentError, /create|new/i)
  end

  it 'validates every local record lifecycle before it evaluates collection grants' do
    persisted = create(:role, organisation: organisation)
    new_record = Role.new(organisation: organisation)

    expect {
      Writ::Access.validation(subject: [persisted, new_record], action: :read, context: user)
    }.to raise_error(ArgumentError, /persisted|new|create/i)
  end

  it 'applies the SQL default predicate once around alternative grant branches' do
    Writ::Configuration.register_default_scope(model_name: 'Role') do
      Role.where(name: 'Default SQL Boundary')
    end
    Writ::Configuration.register_scope(model_name: 'Role', scope_name: 'first') { Role.where(description: 'First') }
    Writ::Configuration.register_scope(model_name: 'Role', scope_name: 'second') { Role.where(description: 'Second') }
    create(:permission, role: role, model: 'Role', action: 'read', scopes: ['first'])
    create(:permission, role: role, model: 'Role', action: 'read', scopes: ['second'])

    sql = Writ::Access.filter(context: user, action: :read, records: Role).to_sql

    expect(sql.scan(/"roles"\."name" = 'Default SQL Boundary'/).length).to eq(1)
  end
end
