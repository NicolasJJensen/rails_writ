require 'rails_helper'

RSpec.describe 'block-only rule registration' do
  let(:registry) { Writ::Logic::Registry.new }

  it 'rejects legacy callable registration at the registry boundary' do
    registrations = [
      -> { registry.register_scope(model_name: 'Asset', scope_name: 'visible', callable: -> { Asset.all }) },
      -> { registry.register_default_scope(model_name: 'Asset', callable: -> { Asset.all }) },
      -> { registry.register_condition(name: 'signed_in', callable: -> { true }) },
      -> { registry.register_field_resolver(model_name: 'Asset', callable: ->(**) { :all }) },
      -> { registry.register_creation_validator(model_name: 'Asset', callable: ->(**) { true }) },
      -> { registry.register_update_validator(model_name: 'Asset', callable: ->(**) { true }) }
    ]

    registrations.each do |registration|
      expect(&registration).to raise_error(ArgumentError, /unknown keyword: :callable/)
    end
  end

  it 'stores a block as the internal callable' do
    rule = proc { |context| Asset.where(owner_id: context.id) }

    registry.register_scope(model_name: 'Asset', scope_name: 'owned', &rule)

    expect(registry.get_scope_callable(model_name: 'Asset', scope_name: 'owned')).to equal(rule)
  end

  it 'accepts blocks for every rule registration API' do
    registry.register_default_scope(model_name: 'Asset') { Asset.all }
    registry.register_condition(name: 'signed_in') { true }
    registry.register_field_resolver(model_name: 'Asset') do |context:, action:, record:, fields:|
      fields
    end
    registry.register_creation_validator(model_name: 'Asset') { |context:, record:| true }
    registry.register_update_validator(model_name: 'Asset') { |context:, record:| true }

    expect(registry.default_scope_registered?(model_name: 'Asset')).to be(true)
    expect(registry.condition_registered?(name: 'signed_in')).to be(true)
    expect(registry.field_resolver_for(model_name: 'Asset')).to be_present
    expect(registry.creation_validators_for(model_name: 'Asset').length).to eq(1)
    expect(registry.update_validators_for(model_name: 'Asset').length).to eq(1)
  end

  it 'rejects keyword-only scope blocks before runtime evaluation' do
    expect {
      registry.register_scope(model_name: 'Asset', scope_name: 'required_context') { |context:| context }
    }.to raise_error(ArgumentError, /dispatched positional arguments/)

    expect {
      registry.register_condition(name: 'optional_context') { |context: nil| context }
    }.to raise_error(ArgumentError, /dispatched positional arguments/)
  end

  it 'rejects callable keywords through the configuration registration boundary' do
    expect {
      Writ::Configuration.register_scope(
        model_name: 'Asset', scope_name: 'visible', callable: -> { Asset.all }
      )
    }.to raise_error(ArgumentError, /unknown keyword: :callable/)
  end
end
