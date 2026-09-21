FactoryBot.define do
  factory :permission do
    role
    model { "Asset" }
    action { "read" }

    trait :read_assets do
      model { "Asset" }
      action { "read" }
    end

    trait :update_assets do
      model { "Asset" }
      action { "update" }
    end

    trait :delete_assets do
      model { "Asset" }
      action { "delete" }
    end

    trait :read_users do
      model { "User" }
      action { "read" }
    end
  end
end
