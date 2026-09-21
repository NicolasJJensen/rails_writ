class Organisation < ApplicationRecord
  include Writ::Roleable

  as_roleable(scoping_model: true)

  has_many :users
  has_many :locations
  has_many :assets

  validate :default_role_belongs_to_organisation

  def create_admin_user!(params)
    user = users.create!(**params) # Automatically adds the default role on user creation
    user.roles << roles.find_by!(name: 'Admin')
    user
  end

  private

  def default_role_belongs_to_organisation
    return unless default_user_role && default_user_role.organisation_id != id

    errors.add(:default_user_role, "must belong to this organisation")
  end
end
