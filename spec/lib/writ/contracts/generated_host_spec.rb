require 'rails_helper'
require 'tmpdir'
require 'open3'
require 'generators/writ/migrations/migrations_generator'
require 'generators/writ/models/models_generator'
require 'generators/writ/initializer/initializer_generator'
require 'generators/writ/roleable/roleable_generator'

RSpec.describe 'Generated host lifecycle' do
  [false, true].each do |multi_tenant|
    ['', 'Authorization', 'Authorization::Rules'].each do |namespace|
      it "migrates, grants, filters and deletes assigned roles (tenant=#{multi_tenant}, namespace=#{namespace.inspect})" do
        Dir.mktmpdir do |directory|
          options = ['--roleable-model=Account']
          options << '--multi-tenant' if multi_tenant
          options << "--model-namespace=#{namespace}" unless namespace.empty?
          [Writ::Generators::MigrationsGenerator,
           Writ::Generators::ModelsGenerator,
           Writ::Generators::InitializerGenerator].each do |generator|
            generator.start(options, destination_root: directory)
          end
          output, status = Open3.capture2e(
            RbConfig.ruby, '-I', File.expand_path('../../../../lib', __dir__),
            File.expand_path('../../../support/generated_host_runner.rb', __dir__),
            directory, namespace, 'Account', 'Organisation', multi_tenant.to_s
          )
          expect(status.success?).to be(true), output
          expect(output).to include('GENERATED_HOST_OK')
        end
      end
    end
  end

  it 'uses valid migrations and associations for namespaced host models' do
    Dir.mktmpdir do |directory|
      options = ['--roleable-model=Host::Account', '--scoping-model=Host::Organisation', '--multi-tenant', '--model-namespace=Authorization']
      [Writ::Generators::MigrationsGenerator,
       Writ::Generators::ModelsGenerator,
       Writ::Generators::InitializerGenerator].each do |generator|
        generator.start(options, destination_root: directory)
      end
      %w[Account Organisation].each do |name|
        path = File.join(directory, "app/models/host/#{name.underscore}.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "module Host\n  class #{name} < ApplicationRecord\n    self.table_name = #{name.tableize.inspect}\n  end\nend\n")
        arguments = ["Host::#{name}"]
        arguments << '--scoping-model' if name == 'Organisation'
        Writ::Generators::RoleableGenerator.start(arguments, destination_root: directory)
      end
      output, status = Open3.capture2e(
        RbConfig.ruby, '-I', File.expand_path('../../../../lib', __dir__),
        File.expand_path('../../../support/generated_host_runner.rb', __dir__),
        directory, 'Authorization', 'Host::Account', 'Host::Organisation', 'true'
      )
      expect(status.success?).to be(true), output
    end
  end

  it 'assigns and destroys roles with Rails inference when host and authorization tables share a prefix' do
    stub_const('ReviewAuth::Account', Class.new(ActiveRecord::Base) { self.table_name = 'review_auth_accounts' })
    Dir.mktmpdir do |directory|
      options = ['--roleable-model=ReviewAuth::Account', '--model-namespace=ReviewAuth']
      [Writ::Generators::MigrationsGenerator,
       Writ::Generators::ModelsGenerator,
       Writ::Generators::InitializerGenerator].each do |generator|
        generator.start(options, destination_root: directory)
      end
      output, status = Open3.capture2e(
        RbConfig.ruby, '-I', File.expand_path('../../../../lib', __dir__),
        File.expand_path('../../../support/generated_host_runner.rb', __dir__),
        directory, 'ReviewAuth', 'ReviewAuth::Account', 'Organisation', 'false', '', 'review_auth_accounts'
      )
      expect(status.success?).to be(true), output
      expect(output).to include('GENERATED_HOST_OK')
    end
  end

  %w[uuid string].each do |key_type|
  it "executes generated #{key_type} migrations and associations for custom host keys" do
    Dir.mktmpdir do |directory|
      options = [
        '--roleable-model=Account', '--scoping-model=Organisation', '--multi-tenant',
        "--roleable-primary-key=#{key_type == 'uuid' ? 'account_uuid' : 'account_code'}", "--roleable-primary-key-type=#{key_type}",
        "--scoping-primary-key=#{key_type == 'uuid' ? 'organisation_uuid' : 'organisation_code'}", "--scoping-primary-key-type=#{key_type}"
      ]
      [Writ::Generators::MigrationsGenerator,
       Writ::Generators::ModelsGenerator,
       Writ::Generators::InitializerGenerator].each do |generator|
        generator.start(options, destination_root: directory)
      end
      output, status = Open3.capture2e(
        RbConfig.ruby, '-I', File.expand_path('../../../../lib', __dir__),
        File.expand_path('../../../support/generated_host_runner.rb', __dir__),
        directory, '', 'Account', 'Organisation', 'true', key_type
      )
      expect(status.success?).to be(true), output
      expect(output).to include('GENERATED_HOST_OK')
    end
  end
  end

  it 'rejects invalid model constants before generating any files' do
    Dir.mktmpdir do |directory|
      expect do
        Writ::Generators::ModelsGenerator.new([], { roleable_model: 'User;exit' }, destination_root: directory).invoke_all
      end.to raise_error(ArgumentError, /model|constant/i)
      expect(Dir[File.join(directory, '**/*')]).to be_empty
    end
  end

  it 'makes reusable concerns available to an ActiveRecord-only host' do
    output, status = Open3.capture2e(RbConfig.ruby, '-I', File.expand_path('../../../../lib', __dir__), '-e', <<~'CODE')
      require 'rails_writ'
      puts [Writ::PermissionAssociations, Writ::PermissionJoinValidations, Writ::PolicyHelpers].map(&:name)
    CODE
    expect(status.success?).to be(true), output
    expect(output).to include('Writ::PolicyHelpers')
  end
end
