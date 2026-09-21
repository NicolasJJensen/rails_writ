# frozen_string_literal: true

require_relative "lib/writ/version"

Gem::Specification.new do |spec|
  spec.name = "rails_writ"
  spec.version = Writ::VERSION
  spec.authors = ["Nicolas J Jensen"]
  spec.email = ["nicolasjensen9@gmail.com"]
  spec.summary = "Role-based access control (RBAC) engine for Rails"
  spec.description = "A flexible RBAC system with DSL-based permission definitions, " \
                     "scope-based record filtering, and condition-based access control. " \
                     "Supports both multi-tenant and single-tenant applications."
  spec.license = "MIT"
  spec.homepage = "https://github.com/NicolasJJensen/rails_writ"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues"
  }

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "app/**/*", "config/**/*", "README.md", "CHANGELOG.md", "LICENSE.txt"]
      .select { |f| File.file?(f) }
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.0", "< 9.0"
  spec.add_dependency "railties", ">= 7.0", "< 9.0"
end
