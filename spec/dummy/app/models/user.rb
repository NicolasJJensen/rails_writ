class User < ApplicationRecord
  include Writ::Roleable
  # TODO: Re-enable when Scry::Filterable is implemented
  # include Scry::Filterable

  # region Filtering
  # TODO: Re-enable when Scry::Filterable is implemented
  # has_advanced_filter_permission :attributes, :adv_filter_blacklisted_attributes, type: :blacklist
  # has_advanced_filter_permission :attribute_predicates, type: :whitelist do |auth_obj|
  #   {
  #     name: %i(eq contains starts_with ends_with not_contains),
  #     age: %i(eq gt gte lt lte)
  #   }
  # end
  # has_advanced_filter_permission :associations, type: :whitelist do |auth_obj|
  #   %i(locations service_industries)
  # end
  # has_advanced_filter_permission :association_predicates, type: :whitelist do |auth_obj|
  #   {
  #     locations: %i(has_any has_all has_none),
  #     service_industries: %i(has_any has_all has_none),
  #   }
  # end
  # has_advanced_filter_permission :scopes do |auth_obj|
  #   {
  #     my_scope_name: [:string, :integer],
  #     my_second_scope: [:boolean]
  #   }
  # end

  # def adv_filter_blacklisted_attributes(auth_obj)
  #   blacklisted_attributes = %i(password)
  #   blacklisted_attributes << :email unless auth_obj.can(read: :email)

  #   blacklisted_attributes
  # end
  # endregion

  # region Associations
  as_roleable

  belongs_to :organisation, optional: true

  has_many :check_ins
  has_many :locations, through: :check_ins

  has_one :current_check_in, -> { where(finish: nil).order(start: :desc) }, class_name: 'CheckIn', foreign_key: 'user_id'
  has_one :current_location, through: :current_check_in, source: :location

  has_and_belongs_to_many :service_industries
  # endregion

  # region Validations
  validate :organisation_cannot_change, on: :update
  # endregion

  # region Scopes

  scope :at_location, ->(location_id) { joins(:check_ins).where(check_ins: { location_id: location_id, finish: nil }) }
  scope :managed_by, ->(_user) { none }

  # endregion

  # region Hooks

  # Role Hooks
  before_create { roles << organisation.default_user_role if organisation&.default_user_role }

  # endregion

  # region Methods
  # endregion

  # region Private Methods

  def organisation_cannot_change
    if will_save_change_to_attribute?(:organisation_id) && persisted?
      errors.add(:organisation_id, "cannot be changed once set. Use UserTransferService for legitimate transfers.")
    end
  end

  # endregion

  # region Class Methods
  # endregion
end
