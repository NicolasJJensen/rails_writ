require 'rails_helper'

RSpec.describe Writ::RecordLookup do
  let(:attributes) { { model: 'Asset', name: 'lookup_scope' } }
  let!(:winner) { Scope.create!(attributes) }

  it 'recovers when another writer wins before uniqueness validation' do
    allow(Scope).to receive(:find_or_create_by!).with(attributes) { Scope.create!(attributes) }
    expect(described_class.find_or_create!(Scope, attributes)).to eq(winner)
  end

  it 'recovers a unique index collision after leaving the savepoint' do
    allow(Scope).to receive(:find_or_create_by!).with(attributes) { Scope.insert_all!([attributes]) }
    expect(described_class.find_or_create!(Scope, attributes)).to eq(winner)
    expect(Scope.count).to be_positive
  end

  it 'preserves other validation errors even if a matching row exists' do
    loser = Scope.new(attributes)
    loser.errors.add(:name, :taken)
    loser.errors.add(:model, :invalid)
    allow(Scope).to receive(:find_or_create_by!).with(attributes).and_raise(ActiveRecord::RecordInvalid.new(loser))
    expect { described_class.find_or_create!(Scope, attributes) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'preserves a collision error if no matching record exists' do
    other = { model: 'Asset', name: 'missing_lookup_scope' }
    allow(Scope).to receive(:find_or_create_by!).with(other).and_raise(ActiveRecord::RecordNotUnique)
    expect { described_class.find_or_create!(Scope, other) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'recovers role creation collisions through the same helper' do
    organisation = create(:organisation)
    role = organisation.roles.first
    relation = organisation.roles
    allow(relation).to receive(:find_or_create_by!).with({ name: role.name }) { relation.create!(name: role.name) }
    expect(described_class.find_or_create!(relation, name: role.name)).to eq(role)
  end
end
