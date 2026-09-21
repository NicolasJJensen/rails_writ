class Permission < ApplicationRecord
  include Writ::PermissionAssociations

  belongs_to :role
  has_one :organisation, through: :role

  validates :action, presence: true,
                     format: { with: Writ::NAME_FORMAT,
                               message: "must be lowercase, start with a letter, and contain only letters, numbers, and underscores" }
  validates :model, presence: true
  validates :role, presence: true
end
