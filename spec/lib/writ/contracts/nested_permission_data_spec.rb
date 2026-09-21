require 'rails_helper'
require 'rake'

RSpec.describe 'Nested permission data contracts' do
  let(:config) { Writ::Configuration }
  let(:generator) { Writ::Generator }

  around do |example|
    previous_registry = config.registry
    previous_configure_blocks = config.instance_variable_get(:@configure_blocks)&.dup
    @organisation = create(:organisation)
    previous_rake = Rake.application
    previous_env = ENV.to_h.slice('CONFIRM', 'DRY_RUN')
    config.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    example.run
  ensure
    config.instance_variable_set(:@registry, previous_registry)
    config.instance_variable_set(:@configure_blocks, previous_configure_blocks)
    Rake.application = previous_rake
    %w[CONFIRM DRY_RUN].each { |key| previous_env.key?(key) ? ENV[key] = previous_env[key] : ENV.delete(key) }
    Current.reset
  end

  def cleanup_for(role)
    allow(config).to receive(:role_class).and_return(Role.where(id: role.id))
    allow(config).to receive(:scope_class).and_return(Scope.none)
    allow(config).to receive(:condition_class).and_return(Condition.none)
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path('../../../../lib/tasks/writ.rake', __dir__)
    ENV['CONFIRM'] = '1'
    ENV.delete('DRY_RUN')
    Rake::Task['writ:cleanup'].invoke
  end

  %i[scope condition].each do |kind|
    it "preserves generated #{kind} grants containing hashes inside arrays across cleanup and reruns" do
      schema = { rules: { type: :array, required: true } }
      if kind == :scope
        config.register_scope(model_name: 'Asset', scope_name: 'nested_rules', arguments: schema) { |_ctx, _args| Asset.all }
      else
        config.register_condition(name: 'nested_rules', arguments: schema) { |_ctx, _args| true }
      end
      entries = [{ nested_rules: { rules: [{ location_id: 1, enabled: false }, { location_id: 2 }] } }]
      config.configure do
        permission :read, model: Asset, role: :NestedReviewer, **{ "#{kind}s".to_sym => entries }
      end
      generator.add_permissions(@organisation, permissions: [{ model: Asset, action: :read }])
      role = @organisation.roles.find_by!(name: 'NestedReviewer')
      permission = role.permissions.first
      original_id = permission.id
      expect(generator.managed_permission?(permission.reload)).to be(true)
      cleanup_for(role)
      expect(Permission.exists?(original_id)).to be(true)
      generator.add_permissions(@organisation, permissions: [{ model: Asset, action: :read }])
      expect(role.permissions.pluck(:id)).to eq([original_id])
    end

    it "creates and updates nested #{kind} attachments through a new permission" do
      catalog = if kind == :scope
        config.register_scope(model_name: 'Asset', scope_name: 'nested_rules', arguments: { ids: { type: :array } }) { |_ctx, args| Asset.where(id: args[:ids]) }
        Scope.create!(model: 'Asset', name: 'nested_rules')
      else
        config.register_condition(name: 'nested_rules', arguments: { ids: { type: :array } }) { |_ctx, args| args[:ids].any? }
        Condition.create!(name: 'nested_rules')
      end
      role = create(:role, organisation: @organisation)
      association = "permission_#{kind}s"
      nested_key = "#{association}_attributes"
      permission = role.permissions.build(model: 'Asset', action: 'read',
        nested_key => [{ "#{kind}_id" => catalog.id, arguments: { ids: [1] } }])
      expect(permission.save).to be(true), permission.errors.full_messages.inspect
      attachment = permission.public_send(association).first
      expect(attachment.permission).to equal(permission)
      expect(permission.reload.public_send(association).first.arguments).to eq('ids' => [1])
      permission.update!(nested_key => [{ id: attachment.id, arguments: { ids: [2] } }])
      expect(permission.reload.public_send(association).first.arguments).to eq('ids' => [2])
    end

    it "allows destroying one nested #{kind} attachment while preserving its sibling" do
      catalog = if kind == :scope
        config.register_scope(model_name: 'Asset', scope_name: 'first_rule') { |_ctx| Asset.all }
        config.register_scope(model_name: 'Asset', scope_name: 'second_rule') { |_ctx| Asset.all }
        Scope.create!(model: 'Asset', name: 'first_rule')
      else
        config.register_condition(name: 'first_rule') { true }
        config.register_condition(name: 'second_rule') { true }
        Condition.create!(name: 'first_rule')
      end
      sibling = if kind == :scope
        Scope.create!(model: 'Asset', name: 'second_rule')
      else
        Condition.create!(name: 'second_rule')
      end
      role = create(:role, organisation: @organisation)
      association = "permission_#{kind}s"
      nested_key = "#{association}_attributes"
      permission = role.permissions.create!(model: 'Asset', action: 'read',
        nested_key => [
          { "#{kind}_id" => catalog.id, arguments: {} },
          { "#{kind}_id" => sibling.id, arguments: {} }
        ])
      first, second = permission.public_send(association).sort_by(&:id)

      permission.update!(nested_key => [{ id: first.id, _destroy: true }])

      expect(permission.reload.public_send(association).map { |entry| entry.public_send(kind).name }).to eq([second.public_send(kind).name])
    end

    it "restores nested #{kind} attachments after a rolled-back destruction" do
      catalog = if kind == :scope
        config.register_scope(model_name: 'Asset', scope_name: 'rollback_first') { |_ctx| Asset.all }
        config.register_scope(model_name: 'Asset', scope_name: 'rollback_second') { |_ctx| Asset.all }
        Scope.create!(model: 'Asset', name: 'rollback_first')
      else
        config.register_condition(name: 'rollback_first') { true }
        config.register_condition(name: 'rollback_second') { true }
        Condition.create!(name: 'rollback_first')
      end
      sibling = if kind == :scope
        Scope.create!(model: 'Asset', name: 'rollback_second')
      else
        Condition.create!(name: 'rollback_second')
      end
      role = create(:role, organisation: @organisation)
      association = "permission_#{kind}s"
      nested_key = "#{association}_attributes"
      permission = role.permissions.create!(model: 'Asset', action: 'read',
        nested_key => [
          { "#{kind}_id" => catalog.id, arguments: {} },
          { "#{kind}_id" => sibling.id, arguments: {} }
        ])
      first = permission.public_send(association).find { |entry| entry.public_send(kind).id == catalog.id }

      Permission.transaction(requires_new: true) do
        permission.update!(nested_key => [{ id: first.id, _destroy: true }])
        raise ActiveRecord::Rollback
      end

      expect(permission.reload.public_send(association).map { |entry| entry.public_send(kind).name })
        .to contain_exactly(catalog.name, sibling.name)
    end
  end

  it 'canonicalizes keys inside nested arrays without changing values, array order or the input' do
    input = { gate: { rules: [{ z: false, a: [{ code: 'first', details: {} }] }, {}, nil, ['second', { id: 2 }]] }, plain: {} }
    original = input.deep_dup
    expected = { 'gate' => { 'rules' => [{ 'a' => [{ 'code' => 'first', 'details' => {} }], 'z' => false }, {}, nil, ['second', { 'id' => 2 }]] } }
    result = config.canonical_arguments(input)
    expect(result).to eq(expected)
    expect(result['gate']['rules'].first.keys).to eq(%w[a z])
    result['gate']['rules'].first['a'].first['code'].replace('changed')
    expect(input).to eq(original)
  end
end
