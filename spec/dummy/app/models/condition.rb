class Condition < ApplicationRecord
  has_many :permission_conditions, dependent: :restrict_with_error
  has_many :permissions, through: :permission_conditions

  validates :name, presence: true,
                   format: { with: Writ::NAME_FORMAT,
                             message: "must be lowercase, start with a letter, and contain only letters, numbers, and underscores" },
                   uniqueness: true
end
