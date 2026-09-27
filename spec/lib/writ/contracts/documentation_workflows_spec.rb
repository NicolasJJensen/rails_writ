require 'rails_helper'
require 'tmpdir'
require 'open3'
require 'generators/writ/migrations/migrations_generator'
require 'generators/writ/models/models_generator'
require 'generators/writ/initializer/initializer_generator'

RSpec.describe 'Documented setup workflows' do
  %w[core pundit].each do |integration|
    [false, true].each do |multi_tenant|
      it "enforces records, fields and proposed state (#{integration}, tenant=#{multi_tenant})" do
        Dir.mktmpdir do |directory|
          arguments = multi_tenant ? ['--multi-tenant'] : []
          [Writ::Generators::MigrationsGenerator, Writ::Generators::ModelsGenerator,
           Writ::Generators::InitializerGenerator].each do |generator|
            generator.start(arguments, destination_root: directory)
          end
          output, status = Open3.capture2e(
            RbConfig.ruby, File.expand_path('../../../support/documentation_host_runner.rb', __dir__),
            directory, multi_tenant.to_s, integration
          )
          expect(status.success?).to be(true), output
          expect(output).to include('DOCUMENTED_WORKFLOW_OK')
        end
      end
    end
  end
end
