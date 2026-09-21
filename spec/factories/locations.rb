FactoryBot.define do
  factory :location do
    organisation
    sequence(:name) { |n| "Location #{n}" }
  end
end
