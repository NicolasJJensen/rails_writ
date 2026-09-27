# frozen_string_literal: true

module Writ
  class Engine < Rails::Engine
    config.writ = ActiveSupport::OrderedOptions.new
    config.writ.definitions_dir = 'config/writ'
    config.writ.definition_loaders = []
    config.writ.default_role_name = 'Default Role'

    initializer 'writ.configure' do |app|
      definitions_path = app.root.join(app.config.writ.definitions_dir)
      app.config.watchable_dirs[definitions_path.to_s] = [:rb]
      prepared = false
      # Rails may prepare repeatedly without unloading application classes.
      # Rebuild after unloading, when their declarations can run again.
      app.reloader.before_class_unload { prepared = false }
      app.config.to_prepare do
        cfg = Rails.application.config.writ
        Writ::Configuration.default_role_name ||= cfg.default_role_name

        next if prepared
        Writ::Configuration.rebuild! do
          Dir[definitions_path.join('**/*.rb')].sort.each { |path| load path }
          cfg.definition_loaders.each(&:call)
        end
        prepared = true
      end
    end
  end

  # Backward compatibility alias
  Railtie = Engine
end
