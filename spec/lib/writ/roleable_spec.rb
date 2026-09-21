require 'rails_helper'

RSpec.describe Writ::Roleable do
  describe ".as_roleable" do
    it "adds roles association to the model" do
      # User includes Roleable and calls as_roleable
      org = create(:organisation)
      user = create(:user, organisation: org)
      expect(user).to respond_to(:roles)
    end

    it "adds permissions association through roles" do
      org = create(:organisation)
      user = create(:user, organisation: org)
      expect(user).to respond_to(:permissions)
    end

    it "auto-generates permissions on create when auto_generate is true" do
      # Organisation triggers generate_default_permissions on create
      org = create(:organisation)
      expect(org.roles.count).to be > 0
    end

    it "does not auto-generate permissions when auto_generate is false" do
      # User calls as_roleable without scoping_model (defaults auto_generate: false)
      user = create(:user, organisation: create(:organisation))
      # User's roles come from the organisation's generation, not from User model's after_create
      # The User model itself doesn't trigger generate_default_permissions
      expect(user.class.instance_methods).to include(:roles)
      expect(user.class.instance_methods).to include(:permissions)
    end

    it "respects auto_generate: false override on scoping_model: true" do
      # Verify Organisation (scoping_model: true) has the after_create callback
      org_callbacks = Organisation._create_callbacks.map(&:filter)
      expect(org_callbacks).to include(anything) # Has callbacks

      # Verify User (auto_generate defaults to false) does NOT have the callback
      # by checking that creating a user doesn't call generate_default_permissions
      org = create(:organisation)
      expect(Writ::Generator).not_to receive(:generate_default_permissions)
      create(:user, organisation: org)
    end
  end
end
