require 'rails_helper'
require 'tmpdir'
require 'shellwords'
require 'generators/writ/pundit/install/install_generator'
require 'generators/writ/migrations/migrations_generator'
require 'generators/writ/models/models_generator'
require 'generators/writ/initializer/initializer_generator'
require 'generators/writ/roleable/roleable_generator'

RSpec.describe 'Pundit installer' do
  [false, true].each do |multi_tenant|
    it "composes core installation and the policy base (tenant=#{multi_tenant})" do
      Dir.mktmpdir do |directory|
        names = multi_tenant ? %w[User Organisation] : %w[User]
        names.each do |name|
          path = File.join(directory, "app/models/#{name.underscore}.rb")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "class #{name} < ApplicationRecord\nend\n")
        end
        installer = Writ::Pundit::Generators::InstallGenerator.new(
          [], { multi_tenant: multi_tenant }, destination_root: directory
        )
        allow(installer).to receive(:generate) do |name, arguments = ''|
          Rails::Generators.invoke(name, Shellwords.split(arguments), destination_root: directory)
        end
        installer.invoke_all
        expect(File.read(File.join(directory, 'app/policies/application_policy.rb')))
          .to include('ApplicationPolicy < Writ::Pundit::Policy')
        expect(File).not_to exist(File.join(directory, 'app/policies/concerns/conditions.rb'))
        expect(File).to exist(File.join(directory, 'config/writ/permissions.rb'))
        expect(File.read(File.join(directory, 'app/models/user.rb'))).to include('as_roleable')
        expect(Dir[File.join(directory, 'db/migrate/*.rb')].length).to eq(multi_tenant ? 8 : 7)
      end
    end
  end
end
