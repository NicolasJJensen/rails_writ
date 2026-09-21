# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rails", "~> 7.0.4"

# These stay out of the default group. factory_bot_rails installs a railtie that
# rebinds FactoryBot.definition_file_paths to the dummy app root, which does not
# hold the suite's factories.
group :development do
  gem "pg", "~> 1.1"
  gem "rspec-rails", ">= 6.0", "< 9.0"
  gem "factory_bot_rails", "~> 6.2"
  gem "pundit", "~> 2.3"
end
