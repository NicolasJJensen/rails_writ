require 'rails_helper'
require 'open3'

RSpec.describe 'Core without the Pundit adapter' do
  it 'loads ActiveRecord concerns without loading Pundit or policy helpers' do
    output, status = Open3.capture2e(RbConfig.ruby, '-e', <<~'RUBY')
      require 'rails_writ'
      abort 'Pundit loaded' if defined?(::Pundit) || defined?(Writ::Pundit)
      abort 'policy helpers loaded' if defined?(Writ::PolicyHelpers)
      abort 'missing concerns' unless Writ::PermissionAssociations && Writ::Roleable
      puts 'CORE_ONLY_OK'
    RUBY
    expect(status.success?).to be(true), output
    expect(output).to include('CORE_ONLY_OK')
  end

  %w[development production].each do |environment|
    it "loads core definitions and rebuilds with current models in #{environment}" do
      output, status = Open3.capture2e({ 'RAILS_ENV' => environment, 'SECRET_KEY_BASE' => 'test-secret-' * 8, 'DATABASE_URL' => ENV.fetch('DATABASE_URL', 'postgresql:///writ_test') }, RbConfig.ruby, '-e', <<~'RUBY')
        require 'rails'
        require 'active_record/railtie'
        require 'rails_writ'
        require 'tmpdir'
        require 'fileutils'
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p("#{root}/config/writ")
          FileUtils.mkdir_p("#{root}/app/models")
          File.write("#{root}/app/models/widget.rb", "class Widget < ActiveRecord::Base; end")
          File.write("#{root}/config/writ/permissions.rb", <<~DEFINITIONS)
            Writ.configure do |config|
              config.multi_tenant = false
              allow_missing_default_scope model: Widget
              scope(:visible, model: Widget) { Widget.all }
              permission :read, model: Widget, role: :Reader, scopes: [:visible]
            end
          DEFINITIONS
          module CoreHost
            class Application < Rails::Application; end
          end
          app = CoreHost::Application
          app.config.load_defaults 7.0
          app.config.root = root
          app.config.eager_load = Rails.env.production?
          app.config.cache_classes = Rails.env.production?
          app.config.secret_key_base = ENV.fetch('SECRET_KEY_BASE')
          app.config.file_watcher = ActiveSupport::FileUpdateChecker
          app.config.logger = Logger.new(File::NULL)
          app.initialize!
          abort 'Pundit loaded' if defined?(::Pundit) || defined?(Writ::Pundit)
          config = Writ::Configuration
          before = config.all_permissions
          abort 'no definitions' if before.empty?
          previous_model = Widget
          unless Rails.env.production?
            Rails.application.reloader.reload!
            abort 'model not reloaded' if Widget.equal?(previous_model)
            File.write("#{root}/config/writ/new_rules.rb", "Writ.configure { permission :update, model: Widget, role: :Reader }")
            Rails.application.reloader.wrap {}
            abort 'definition edit not reloaded' if config.all_permissions == before
            before = config.all_permissions
          end
          abort 'lost definitions' unless config.all_permissions == before
          scope = config.get_scope_callable(model_name: 'Widget', scope_name: 'visible')
          abort 'stale model' unless scope.call.klass.equal?(Widget)
          puts 'CORE_RAILS_OK'
        end
      RUBY
      expect(status.success?).to be(true), output
      expect(output).to include('CORE_RAILS_OK')
    end
  end
end
