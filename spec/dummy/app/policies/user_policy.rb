# frozen_string_literal: true

# User Permission Policy
# Defines scopes and permissions for the User model
class UserPolicy < ApplicationPolicy
  # ============================================
  # DEFAULT SCOPE
  # ============================================

  default_scope do
    User.where(organisation: Current.organisation)
  end

  # ============================================
  # SCOPES
  # ============================================

  scope :at_current_location do
    location = Current.user&.current_location
    location ? User.at_location(location.id) : User.none
  end

  scope :managed_by do
    User.managed_by(Current.user)
  end

  # ============================================
  # PERMISSIONS
  # ============================================

  # Default Role permissions
  role :'Default Role' do
    permission :read, scopes: [:at_current_location, :managed_by]
    accessible_fields [:name, :email]
  end

  # Standard Supervisor permissions
  role :'Standard Supervisor' do
    permission :read, scopes: [:at_current_location]
    permission :update, scopes: [:at_current_location]
    accessible_fields :all
  end

  # Manager permissions
  role :Manager do
    permission :read
    permission :update
    accessible_fields :all
  end

  # Admin permissions
  role :Admin do
    permission :read
    permission :create
    permission :update
    permission :delete
    accessible_fields :all
  end
end
