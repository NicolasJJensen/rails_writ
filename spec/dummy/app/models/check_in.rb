class CheckIn < ApplicationRecord
  # region Associations
  belongs_to :user
  has_one :organisation, through: :user
  belongs_to :location
  # endregion

  # region Scopes
  # endregion

  # region Hooks
  # endregion

  # region Methods
  # endregion

  # region Private Methods
  # endregion

  # region Class Methods
  # endregion
end