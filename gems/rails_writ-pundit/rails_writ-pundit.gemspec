# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = 'rails_writ-pundit'
  spec.version = '0.1.0'
  spec.authors = ['Nicolas J Jensen']
  spec.summary = 'Pundit policies and generators for Writ authorization'
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/NicolasJJensen/rails_writ'
  spec.required_ruby_version = '>= 3.1.0'
  spec.files = Dir.chdir(__dir__) { Dir['lib/**/*', 'README.md', 'LICENSE.txt'].select { |path| File.file?(path) } }
  spec.require_paths = ['lib']
  spec.add_dependency 'rails_writ', '~> 0.1.0'
  spec.add_dependency 'pundit', '>= 2.5', '< 3.0'
end
