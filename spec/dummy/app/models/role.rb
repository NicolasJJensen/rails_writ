class Role < ApplicationRecord
  belongs_to :organisation

  has_many :permissions, dependent: :destroy
  has_and_belongs_to_many :users

  accepts_nested_attributes_for :permissions

  validates :name, presence: true, uniqueness: { scope: :organisation_id }
  validates :organisation, presence: true
end
