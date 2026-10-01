# frozen_string_literal: true

# Asset Permission Policy
# Defines scopes and permissions for the Asset model
class AssetPolicy < ApplicationPolicy
  def publish?
    permitted?(:publish)
  end

  # ============================================
  # DEFAULT SCOPE
  # ============================================

  default_scope do
    query do
      Asset.where(organisation: Current.organisation)
    end
  end

  # ============================================
  # SCOPES
  # ============================================
  # Descriptions are in config/locales/writ.en.yml

  scope :service_industry do
    query do
      Asset.joins(:service_industries)
           .where(service_industries: { id: Current.user.service_industries })
    end
  end

  scope :current_location do
    query do
      current_location_id = Current.user.check_ins.where(finish: nil).order(start: :desc).limit(1).select(:location_id)
      Asset.where(location: current_location_id)
    end
  end

  scope :created do
    query do
      # Note: Asset model doesn't have created_by_id field yet
      Asset.none
    end
  end

  scope :status_active do
    query do
      Asset.where(status: :satisfactory)
    end
  end

  # ============================================
  # PERMISSIONS
  # ============================================

  # Technician permissions
  role :Technician do
    permission :read, scopes: [:service_industry, :current_location]
    permission :create, scopes: [:service_industry, :current_location]
    permission :update, scopes: [:current_location]
    accessible_fields :all
  end

  # Technician Supervisor permissions
  role :'Technician Supervisor' do
    permission :read, scopes: [:service_industry]
    permission :update, scopes: [:service_industry]
    permission :delete, scopes: [:current_location]
    accessible_fields :all
  end

  # Admin permissions (unrestricted)
  role :Admin do
    permission :read
    permission :create
    permission :update
    permission :delete
    permission :publish
    accessible_fields :all
  end
end
