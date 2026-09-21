class Asset < ApplicationRecord
  enum :status, [:satisfactory, :maintenance_recommended, :maintenance_required, :replacement_needed]

  belongs_to :organisation
  belongs_to :location
  validates :name, presence: true

  has_and_belongs_to_many :locations
  has_and_belongs_to_many :service_industries
end
