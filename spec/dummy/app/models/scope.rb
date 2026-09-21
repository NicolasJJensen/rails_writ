class Scope < ApplicationRecord
  has_many :permission_scopes, dependent: :restrict_with_error
  has_many :permissions, through: :permission_scopes

  validates :name, presence: true,
                   format: { with: Writ::NAME_FORMAT,
                             message: "must be lowercase, start with a letter, and contain only letters, numbers, and underscores" }
  validates :model, presence: true
  validates :name, uniqueness: { scope: :model }
end
