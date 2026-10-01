# frozen_string_literal: true

# CheckIn Permission Policy
# Defines scopes and permissions for the CheckIn model
class CheckInPolicy < ApplicationPolicy
  # ============================================
  # SCOPES
  # ============================================

  default_scope do
    query do
      CheckIn.joins(:user).where(users: { organisation: Current.organisation })
    end
  end

  scope :current_location do
    query do
      current_location_id = Current.user.check_ins.where(finish: nil).order(start: :desc).limit(1).select(:location_id)
      CheckIn.where(location_id: current_location_id)
    end
  end

  scope :own do
    query do
      CheckIn.where(user: Current.user)
    end
  end

  # ============================================
  # PERMISSIONS
  # ============================================

  # Technician permissions
  role :Technician do
    permission :read, scopes: [:own]
    permission :update, scopes: [:current_location, :own]
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
