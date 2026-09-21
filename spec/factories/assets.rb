FactoryBot.define do
  factory :asset do
    organisation
    location
    sequence(:name) { |n| "Asset #{n}" }
    description { "Test asset description" }
    status { :satisfactory }
    archived { false }
  end
end
