# frozen_string_literal: true

module Writ
  class Engine < Rails::Engine
    config.writ = ActiveSupport::OrderedOptions.new
    config.writ.policies_dir = 'app/policies'
    config.writ.default_role_name = 'Default Role'

    initializer 'writ.configure' do |app|
      prepared = false
      # Rails may prepare repeatedly without unloading policy classes.
      # Rebuild after unloading, when their declarations can run again.
      app.reloader.before_class_unload { prepared = false }
      app.config.to_prepare do
        cfg = Rails.application.config.writ
        Writ::Configuration.default_role_name ||= cfg.default_role_name

        next if prepared
        Writ::Configuration.rebuild! do
          policies_path = Rails.root.join(cfg.policies_dir)
          Rails.autoloaders.main.eager_load_dir(policies_path) if policies_path.exist?
        end
        prepared = true
      end
    end
  end

  # Backward compatibility alias
  Railtie = Engine
end
