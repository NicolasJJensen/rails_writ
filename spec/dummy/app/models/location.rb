class Location < ApplicationRecord
  belongs_to :organisation
  has_many :users
  has_many :assets
end
