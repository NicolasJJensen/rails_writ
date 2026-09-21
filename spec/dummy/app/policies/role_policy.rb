# frozen_string_literal: true

# Role Permission Policy
# Defines permissions for the Role model
class RolePolicy < ApplicationPolicy
  # ============================================
  # DEFAULT SCOPE
  # ============================================

  default_scope do
    Role.where(organisation: Current.organisation)
  end

  # ============================================
  # PERMISSIONS
  # ============================================

  # Default Role permissions
  role :'Default Role' do
    permission :read
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
