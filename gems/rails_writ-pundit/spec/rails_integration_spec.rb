require 'rails_helper'
require 'open3'
require 'pundit'

RSpec.describe 'Rails and Pundit boundaries' do
  it 'loads policy definitions on eager boot and after real class unloading' do
    environment = Rails.root.join('config/environment').to_s
    ['production', 'development'].each do |mode|
      script = <<~RUBY_CODE
        ENV['RAILS_ENV'] = #{mode.inspect}
        require #{environment.inspect}
        config = Writ::Configuration
        before = config.registry.all_permissions
        raise 'empty definitions' if before.empty?
        if #{mode.inspect} == 'production'
          Rails.application.eager_load!
        else
          previous_asset = Asset
          Rails.application.reloader.reload!
          raise 'classes did not unload' if Asset.equal?(previous_asset)
        end
        raise 'definitions changed' unless config.registry.all_permissions == before
        puts 'LIFECYCLE_OK'
      RUBY_CODE
      output, status = Open3.capture2e({ 'SECRET_KEY_BASE' => 'test-only-secret-' * 8, 'DATABASE_URL' => ENV.fetch('DATABASE_URL', 'postgresql:///writ_test') }, RbConfig.ruby, '-e', script)
      expect(status.success?).to be(true), output
      expect(output).to include('LIFECYCLE_OK')
    end
  end

  it 'resolves policy scopes and authorizes through Pundit itself' do
    organisation = create(:organisation)
    user = create(:user, organisation: organisation)
    Current.user = user
    role = create(:role, organisation: organisation)
    user.roles = [role]
    asset = create(:asset, organisation: organisation)
    create(:permission, role: role, action: :read)
    expect(Pundit.authorize(user, asset, :show?)).to eq(asset)
    expect(Pundit.policy_scope!(user, Asset).pluck(:id)).to include(asset.id)
    expect { Pundit.authorize(user, asset, :update?) }.to raise_error(Pundit::NotAuthorizedError)
  ensure
    Current.reset
  end

  it 'uses explicit custom predicates and rejects unknown predicates in the dummy host' do
    organisation = create(:organisation)
    user = create(:user, organisation: organisation)
    Current.user = user
    role = create(:role, organisation: organisation)
    user.roles = [role]
    asset = create(:asset, organisation: organisation)
    create(:permission, role: role, action: :publish)

    expect(Pundit.authorize(user, asset, :publish?)).to eq(asset)
    expect(Pundit.policy(user, asset)).to respond_to(:publish?)
    expect(Pundit.policy(user, asset)).not_to respond_to(:typo?)
    expect { Pundit.authorize(user, asset, :typo?) }.to raise_error(NoMethodError)
  ensure
    Current.reset
  end
end
