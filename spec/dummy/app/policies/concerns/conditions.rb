# frozen_string_literal: true

# Conditions Concern
# Defines all reusable conditions for permissions across the application.
# Uses the `condition` DSL method from Writ::PolicyHelpers.
# Include this in ApplicationPolicy (after Writ::PolicyHelpers) to make conditions available to all policies.
module Conditions
  extend ActiveSupport::Concern

  included do
    # ============================================
    # TIME-BASED CONDITIONS
    # ============================================

    condition :business_hours do |_context|
      hour = Time.zone.current.hour
      weekday = [1, 2, 3, 4, 5].include?(Time.zone.current.wday) # Monday-Friday
      (9..17).cover?(hour) && weekday
    end

    condition :after_hours do |_context|
      hour = Time.zone.current.hour
      weekend = [0, 6].include?(Time.zone.current.wday) # Saturday-Sunday
      !(9..17).cover?(hour) || weekend
    end

    condition :weekdays_only do |_context|
      [1, 2, 3, 4, 5].include?(Time.zone.current.wday) # Monday-Friday
    end

    condition :weekends_only do |_context|
      [0, 6].include?(Time.zone.current.wday) # Saturday-Sunday
    end

    # ============================================
    # LOCATION-BASED CONDITIONS
    # ============================================

    condition :in_office do |_context|
      # Check if IP address is within office range
      # Set OFFICE_IP_PREFIX environment variable (e.g., "192.168.1")
      office_prefix = ENV['OFFICE_IP_PREFIX']
      next true if office_prefix.blank?  # Allow if not configured

      Current.ip_address&.start_with?(office_prefix)
    end

    condition :on_site_location do |context|
      # Check if context (user) is checked in at an on-site location
      context.current_location&.on_site? || false
    end

    # ============================================
    # DEVICE-BASED CONDITIONS
    # ============================================

    condition :desktop_only do |_context|
      Current.device_type == :desktop
    end

    condition :mobile_allowed do |_context|
      true  # Always allowed - placeholder for consistency
    end

    # ============================================
    # SECURITY CONDITIONS
    # ============================================

    condition :mfa_only do |_context|
      # TODO: MFA verification when MFA system is added
      # For now, always return true to not block access
      true
    end
  end
end
