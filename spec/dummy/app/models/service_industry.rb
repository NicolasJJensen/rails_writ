class ServiceIndustry < ApplicationRecord
    # region Associations
    belongs_to :organisation

    has_and_belongs_to_many :users
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