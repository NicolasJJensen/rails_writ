require 'rails_helper'
require 'tmpdir'
require 'shellwords'
require 'generators/writ/install/install_generator'
require 'generators/writ/migrations/migrations_generator'
require 'generators/writ/models/models_generator'
require 'generators/writ/initializer/initializer_generator'
require 'generators/writ/roleable/roleable_generator'

RSpec.describe 'Installer orchestration' do
  it 'fails before creating artifacts when the roleable model is absent' do
    Dir.mktmpdir do |directory|
      installer = Writ::Generators::InstallGenerator.new([], {
        roleable_model: 'Host::Account'
      }, destination_root: directory)

      expect { installer.invoke_all }
        .to raise_error(Thor::Error, /roleable model Host::Account must exist at app\/models\/host\/account\.rb/)
      expect(Dir.children(directory)).to be_empty
    end
  end

  it 'fails before creating artifacts when the multi-tenant scoping model is absent' do
    Dir.mktmpdir do |directory|
      account_path = File.join(directory, 'app/models/host/account.rb')
      FileUtils.mkdir_p(File.dirname(account_path))
      File.write(account_path, "module Host\n  class Account < ApplicationRecord\n  end\nend\n")
      installer = Writ::Generators::InstallGenerator.new([], {
        roleable_model: 'Host::Account', scoping_model: 'Host::Organisation', multi_tenant: true
      }, destination_root: directory)

      expect { installer.invoke_all }
        .to raise_error(Thor::Error, /scoping model Host::Organisation must exist at app\/models\/host\/organisation\.rb/)
      expect(Dir[File.join(directory, 'db/migrate/*.rb')]).to be_empty
      expect(File).not_to exist(File.join(directory, 'app/models/permission.rb'))
      expect(File).not_to exist(File.join(directory, 'config/initializers/writ.rb'))
    end
  end

  it 'runs all generators and injects both module-wrapped host models' do
    Dir.mktmpdir do |directory|
      %w[Account Organisation].each do |name|
        path = File.join(directory, "app/models/host/#{name.underscore}.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "module Host\n  class #{name} < ApplicationRecord\n  end\nend\n")
      end
      installer = Writ::Generators::InstallGenerator.new([], {
        roleable_model: 'Host::Account', scoping_model: 'Host::Organisation',
        multi_tenant: true, model_namespace: 'Authorization'
      }, destination_root: directory)
      # Keep generator subprocesses in this temporary destination while running their real implementations.
      allow(installer).to receive(:generate) do |name, arguments = ''|
        Rails::Generators.invoke(name, Shellwords.split(arguments), destination_root: directory)
      end
      installer.invoke_all
      expect(File.read(File.join(directory, 'app/models/host/account.rb'))).to include('as_roleable')
      expect(File.read(File.join(directory, 'app/models/host/organisation.rb'))).to include('as_roleable(scoping_model: true)')
      expect(File).to exist(File.join(directory, 'app/models/authorization/permission.rb'))
      expect(File).not_to exist(File.join(directory, 'app/policies'))
      expect(File).to exist(File.join(directory, 'config/writ/permissions.rb'))
      expect(File).to exist(File.join(directory, 'config/initializers/writ.rb'))
      expect(Dir[File.join(directory, 'db/migrate/*.rb')].length).to eq(8)
    end
  end
end
