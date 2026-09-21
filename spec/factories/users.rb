FactoryBot.define do
  factory :user do
    organisation
    sequence(:first_name) { |n| "User#{n}" }
    sequence(:last_name) { |n| "Test#{n}" }

    trait :technician do
      first_name { "John" }
      last_name { "Technician" }
      after(:create) do |user|
        user.roles << create(:role, :technician, organisation: user.organisation)
      end
    end

    trait :manager do
      first_name { "Mary" }
      last_name { "Manager" }
      after(:create) do |user|
        user.roles << create(:role, :manager, organisation: user.organisation)
      end
    end

    trait :admin do
      first_name { "Jane" }
      last_name { "Admin" }
      after(:create) do |user|
        user.roles << create(:role, :admin, organisation: user.organisation)
      end
    end
  end
end
