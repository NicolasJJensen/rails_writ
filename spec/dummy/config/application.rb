# frozen_string_literal: true

require_relative 'boot'

require 'rails/all'

Bundler.require(*Rails.groups)
require 'rails_writ'

module Dummy
  class Application < Rails::Application
    config.load_defaults 7.0
    config.api_only = true
    config.eager_load = false

    # Add dummy app's lib to autoload paths (for current_attributes, etc.)
    config.autoload_paths << Rails.root.join('app/models/current_attributes')
    config.eager_load_paths << Rails.root.join('app/models/current_attributes')
  end
end
