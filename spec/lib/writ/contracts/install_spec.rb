require 'rails_helper'
require 'tmpdir'
require 'generators/writ/migrations/migrations_generator'
require 'generators/writ/roleable/roleable_generator'

RSpec.describe 'Fresh installation contracts' do
  [false, true].each do |multi_tenant|
  it "executes generated migrations for an Account host (multi_tenant=#{multi_tenant})" do
    connection = ActiveRecord::Base.connection
    original_path = connection.schema_search_path
    connection.execute('CREATE SCHEMA ap_install_contract')
    connection.schema_search_path = 'ap_install_contract'
    connection.create_table(:accounts)
    connection.create_table(:organisations) if multi_tenant
    Dir.mktmpdir do |directory|
      options = ['--roleable-model=Account']
      options << '--multi-tenant' if multi_tenant
      Writ::Generators::MigrationsGenerator.start(options, destination_root: directory)
      Dir[File.join(directory, 'db/migrate/*.rb')].sort.each do |file|
        # Anonymous classes avoid replacing the dummy application's migration constants.
        code = File.read(file).sub(/class \w+ < ActiveRecord::Migration(\[[^\]]+\])/, 'Class.new(ActiveRecord::Migration\1) do')
        eval(code, TOPLEVEL_BINDING, file).new.migrate(:up)
      end
    end
    expect(connection.foreign_keys('accounts_roles').map(&:to_table)).to contain_exactly('roles', 'accounts')
    expect(connection.columns('permissions').map(&:name)).to include('generated_signature')
    expect(connection.columns('roles').map(&:name)).to include('generated_fields')
  ensure
    connection.schema_search_path = original_path
    connection.schema_cache.clear!
  end

  end

  it 'injects the roleable concern at a namespaced model path' do
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p(File.join(directory, 'app/models/accounts'))
      file = File.join(directory, 'app/models/accounts/user.rb')
      File.write(file, "class Accounts::User < ApplicationRecord\nend\n")
      allow(Rails).to receive(:root).and_return(Pathname.new(directory))
      Writ::Generators::RoleableGenerator.start(['Accounts::User'], destination_root: directory)
      expect(File.read(file)).to include('as_roleable')
    end
  end

  it 'rejects identical roleable and scoping models before writing files' do
    Dir.mktmpdir do |directory|
      expect {
        Writ::Generators::MigrationsGenerator.start(
          ['--multi-tenant', '--roleable-model=Account', '--scoping-model=Account'],
          destination_root: directory
        )
      }.to raise_error(ArgumentError, /different|same|roleable|scoping/i)
      expect(Dir[File.join(directory, '**/*')]).to be_empty
    end
  end

end
