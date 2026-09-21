FactoryBot.define do
  factory :scope do
    model { "Asset" }
    sequence(:name) { |n| "scope_#{n}" }
  end

  factory :condition do
    sequence(:name) { |n| "condition_#{n}" }
  end
end
