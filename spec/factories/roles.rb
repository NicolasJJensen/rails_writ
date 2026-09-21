FactoryBot.define do
  factory :role do
    organisation
    sequence(:name) { |n| "Role #{n}" }
    description { "A test role" }
    color { "#3B82F6" }

    trait :technician do
      name { "Test Technician" }
      description { "Test technician role" }
    end

    trait :manager do
      name { "Test Manager" }
      description { "Test manager role" }
      color { "#10B981" }
    end

    trait :admin do
      name { "Test Admin" }
      description { "Test administrator role" }
      color { "#EF4444" }
    end
  end
end
