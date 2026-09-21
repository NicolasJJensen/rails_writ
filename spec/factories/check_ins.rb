FactoryBot.define do
  factory :check_in do
    user
    location
    start { Time.current }
    finish { nil }

    trait :finished do
      finish { Time.current + 1.hour }
    end
  end
end
