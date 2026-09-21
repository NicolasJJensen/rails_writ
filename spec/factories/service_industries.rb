FactoryBot.define do
  factory :service_industry do
    organisation
    sequence(:name) { |n| "Service Industry #{n}" }
    sequence(:description) { |n| "Description for Service Industry #{n}" }
  end
end
