# frozen_string_literal: true

# Permission Permission Policy
# Defines permissions for the Permission model
class PermissionPolicy < ApplicationPolicy
  # ============================================
  # DEFAULT SCOPE
  # ============================================

  default_scope do
    query do
      Permission.joins(:role).where(roles: { organisation: Current.organisation })
    end
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
