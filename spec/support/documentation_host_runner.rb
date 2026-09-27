# Run README definitions against real generated models in a rollback-only schema.
require 'active_support/all'
require 'active_record'
require 'rails_writ'
require 'rails_writ/pundit' if ARGV[2] == 'pundit'

directory, tenancy, integration = ARGV
multi_tenant = tenancy == 'true'
ActiveRecord::Base.establish_connection(ENV.fetch('DATABASE_URL', 'postgresql:///writ_test'))
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end
class User < ApplicationRecord; end
class Organisation < ApplicationRecord; end
class Asset < ApplicationRecord; end

ActiveRecord::Base.transaction do
  connection = ActiveRecord::Base.connection
  connection.execute("CREATE SCHEMA writ_docs_#{Process.pid}")
  connection.schema_search_path = "writ_docs_#{Process.pid}"
  connection.create_table(:users)
  connection.create_table(:organisations) if multi_tenant
  connection.create_table(:assets) do |table|
    table.bigint :owner_id
    table.bigint :organisation_id if multi_tenant
    table.string :name
    table.string :description
  end
  Dir[File.join(directory, 'db/migrate/*.rb')].sort.each do |file|
    code = File.read(file).sub(/class \w+ < ActiveRecord::Migration(\[[^\]]+\])/, 'Class.new(ActiveRecord::Migration\1) do')
    eval(code, TOPLEVEL_BINDING, file).new.migrate(:up)
  end
  load File.join(directory, 'config/initializers/writ.rb')
  Dir[File.join(directory, 'app/models/*.rb')].sort.each { |path| load path }
  User.include(Writ::Roleable)
  User.as_roleable
  if multi_tenant
    Organisation.include(Writ::Roleable)
    Organisation.as_roleable(scoping_model: true)
  end

  snippets = File.read(File.expand_path('../../README.md', __dir__)).scan(/^```ruby\n(.*?)^```/m).flatten
  contexts = snippets.select { |code| code.include?('class AuthorizationContext') }
  eval(contexts.fetch(multi_tenant ? 1 : 0), TOPLEVEL_BINDING, 'README.md')
  if integration == 'pundit'
    class ApplicationPolicy < Writ::Pundit::Policy; end
    policies = snippets.select { |code| code.include?('class AssetPolicy') }
    eval(policies.fetch(multi_tenant ? 1 : 0), TOPLEVEL_BINDING, 'README.md')
  else
    abort 'adapter loaded in core example' if defined?(::Pundit)
    definitions = snippets.find { |code| code.include?('with_options model: Asset, role: :Member') }
    definitions = definitions.sub('  allow_missing_default_scope model: Asset', '') if multi_tenant
    eval(definitions, TOPLEVEL_BINDING, 'README.md')
    if multi_tenant
      default = snippets.find { |code| code.start_with?('default_scope model: Asset') }
      eval("Writ.configure do\n#{default}\nend", TOPLEVEL_BINDING, 'README.md')
    end
  end

  Writ::Configuration.validate_references!

  user = User.create!
  other_user = User.create!
  organisation = Organisation.create! if multi_tenant
  other_organisation = Organisation.create! if multi_tenant
  Writ::Generator.generate_default_permissions unless multi_tenant
  roles = multi_tenant ? organisation.roles : Role.all
  user.roles << roles.find_by!(name: 'Member')
  # Holding another tenant's role must not broaden this context's grants.
  user.roles << other_organisation.roles.find_by!(name: 'Member') if multi_tenant
  options = { user: user }
  options[:organisation] = organisation if multi_tenant
  context = AuthorizationContext.new(**options)
  attributes = { owner_id: user.id, name: 'Owned asset', description: 'Visible' }
  attributes[:organisation_id] = organisation.id if multi_tenant
  own = Asset.create!(attributes)
  other = Asset.create!(attributes.merge(owner_id: other_user.id))
  foreign = Asset.create!(attributes.merge(organisation_id: other_organisation.id)) if multi_tenant
  access = Writ::Access
  abort 'filter mismatch' unless access.filter(context: context, action: :read, records: Asset.all).pluck(:id) == [own.id]
  abort 'read denied' unless access.authorization(context: context, action: :read, subject: own).allowed?
  abort 'other owner allowed' if access.authorization(context: context, action: :read, subject: other).allowed?
  abort 'foreign tenant allowed' if foreign && access.authorization(context: context, action: :read, subject: foreign).allowed?
  if integration == 'pundit'
    abort 'adapter read' unless Pundit.authorize(context, own, :show?) == own
    abort 'adapter scope' unless Pundit.policy_scope!(context, Asset).pluck(:id) == [own.id]
  end
  abort 'read fields' unless access.readable_fields(context: context, record: own) == %w[name description]
  fields = access.writable_fields(context: context, record: own, action: :update)
  abort 'write fields' unless fields == ['name'] && !(['description'] - fields).empty?
  proposed = Asset.new(attributes)
  abort 'create denied' unless access.validation(context: context, action: :create, subject: proposed).allowed?
  proposed.owner_id = other_user.id
  abort 'create owner bypass' if access.validation(context: context, action: :create, subject: proposed).allowed?
  own.owner_id = other_user.id
  abort 'update owner bypass' if access.validation(context: context, action: :update, subject: own).allowed?
  if multi_tenant
    own.owner_id = user.id
    own.organisation_id = other_organisation.id
    abort 'update tenant bypass' if access.validation(context: context, action: :update, subject: own).allowed?
  end
  puts 'DOCUMENTED_WORKFLOW_OK'
  raise ActiveRecord::Rollback
end
