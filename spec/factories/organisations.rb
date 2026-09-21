FactoryBot.define do
  factory :organisation do
    sequence(:name) { |n| "Organisation #{n}" }

    # The after_create callback will generate default roles and set default_user_role automatically

    trait :acme_corp do
      name { "Acme Corporation" }
    end

    trait :beta_company do
      name { "Beta Company" }
    end
  end
end
