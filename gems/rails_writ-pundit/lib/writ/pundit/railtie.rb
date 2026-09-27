# frozen_string_literal: true

module Writ
  module Pundit
    class Railtie < Rails::Railtie
      initializer 'writ.pundit', before: 'writ.configure' do |app|
        app.config.writ.definition_loaders << lambda do
          path = app.root.join('app/policies')
          Rails.autoloaders.main.eager_load_dir(path) if path.exist?
        end
      end
    end
  end
end
