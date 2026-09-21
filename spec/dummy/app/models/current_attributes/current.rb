class Current < ActiveSupport::CurrentAttributes
  attribute :user, :ip_address, :user_agent, :request_id, :device_type

  # Check if device is mobile based on user agent
  # @return [Boolean]
  def self.mobile_device?
    device_type == :mobile
  end

  def organisation
    user&.organisation
  end

  # Detect device type from user agent
  # @param user_agent_string [String] The user agent string
  # @return [Symbol] :mobile or :desktop
  def self.detect_device_type(user_agent_string)
    return :desktop if user_agent_string.blank?

    mobile_patterns = /Mobile|Android|iPhone|iPad|iPod|Windows Phone|webOS/i
    user_agent_string.match?(mobile_patterns) ? :mobile : :desktop
  end
end
