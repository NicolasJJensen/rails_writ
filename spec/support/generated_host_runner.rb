# Run in a fresh process so generated model constants cannot reuse the dummy app's associations.
require 'active_support/all'
require 'active_record'
require 'securerandom'
require 'rails_writ'
root = File.expand_path('../..', __dir__)
%w[permission_associations permission_join_validations].each do |name|
  require File.join(root, 'app/models/concerns/writ', name)
end

directory, namespace, actor_name, tenant_name, tenant_mode, key_mode, actor_table = ARGV
actor_table ||= 'accounts'
multi_tenant = tenant_mode == 'true'
custom_keys = %w[uuid string].include?(key_mode)
actor_key = key_mode == 'string' ? 'account_code' : 'account_uuid'
tenant_key = key_mode == 'string' ? 'organisation_code' : 'organisation_uuid'
ActiveRecord::Base.establish_connection(ENV.fetch('DATABASE_URL', 'postgresql:///writ_test'))
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end
class Current < ActiveSupport::CurrentAttributes
  attribute :organisation
end
ActiveRecord::Base.belongs_to_required_by_default = true

def host_model(name, table, primary_key = nil)
  parts = name.split('::')
  parent = parts[0...-1].reduce(Object) { |mod, part| mod.const_defined?(part, false) ? mod.const_get(part, false) : mod.const_set(part, Module.new) }
  parent.const_set(parts.last, Class.new(ApplicationRecord) do
    self.table_name = table
    self.primary_key = primary_key if primary_key
  end)
end

ActiveRecord::Base.transaction do
  connection = ActiveRecord::Base.connection
  schema = "ap_generated_#{Process.pid}"
  connection.execute("CREATE SCHEMA #{schema}")
  connection.schema_search_path = schema
  connection.create_table(actor_table, **(custom_keys ? { id: key_mode.to_sym, primary_key: actor_key } : {}))
  connection.create_table(:organisations, **(custom_keys ? { id: key_mode.to_sym, primary_key: tenant_key } : {})) if multi_tenant
  connection.create_table(:documents) { |t| t.string :name; t.column :owner_id, custom_keys ? key_mode.to_sym : :bigint }
  if namespace.present?
    connection.create_table(:roles) { |t| t.string :name }
    existing_role = host_model('Role', 'roles').create!(name: 'Unrelated host role')
  end
  actor = host_model(actor_name, actor_table, custom_keys ? actor_key : nil)
  tenant = host_model(tenant_name, 'organisations', custom_keys ? tenant_key : nil) if multi_tenant
  document = host_model('Document', 'documents')
  Dir[File.join(directory, 'db/migrate/*.rb')].sort.each do |path|
    code = File.read(path).sub(/class \w+ < ActiveRecord::Migration(\[[^\]]+\])/, 'Class.new(ActiveRecord::Migration\1) do')
    eval(code, TOPLEVEL_BINDING, path).new.migrate(:up)
  end
  load File.join(directory, 'config/initializers/writ.rb')
  Dir[File.join(directory, 'app/models/**/*.rb')].sort.each { |path| load path }
  unless actor.respond_to?(:as_roleable)
    actor.include(Writ::Roleable)
    actor.as_roleable
  end
  if tenant && !tenant.respond_to?(:as_roleable)
    tenant.include(Writ::Roleable)
    tenant.as_roleable(scoping_model: true, auto_generate: false)
  end
  owner = tenant&.create!(custom_keys ? { tenant_key => SecureRandom.uuid } : {})
  Current.organisation = owner
  user = actor.create!(custom_keys ? { actor_key => SecureRandom.uuid } : { id: 5_000_000_000 })
  actor_id = user.public_send(actor.primary_key)
  own = document.create!(name: 'own', owner_id: actor_id)
  document.create!(name: 'other', owner_id: custom_keys ? SecureRandom.uuid : user.id + 1)
  Writ.configure do
    allow_missing_default_scope model: document
    scope(:mine, model: document) { |context| document.where(owner_id: context.id) }
    permission :read, model: document, role: 'Reader', scopes: [:mine]
    accessible_fields [:name], model: document, role: 'Reader', action: :read
  end
  Writ::Generator.generate_default_permissions(owner)
  role_class = Writ::Configuration.role_class
  expected_class = [namespace.presence, 'Role'].compact.join('::')
  raise "wrong role class #{role_class.name}" unless role_class.name == expected_class
  role = role_class.find_by!(name: 'Reader')
  Writ.configure { condition(:nested_gate) { true } }
  condition = Writ::Configuration.condition_class.create!(name: 'nested_gate')
  scope = Writ::Configuration.scope_class.find_by!(model: 'Document', name: 'mine')
  nested = role.permissions.build(model: 'Document', action: 'update',
    permission_scopes_attributes: [{ scope_id: scope.id, arguments: {} }],
    permission_conditions_attributes: [{ condition_id: condition.id, arguments: {} }])
  nested.save!
  raise 'missing nested scope inverse' unless nested.permission_scopes.first.permission.equal?(nested)
  raise 'missing nested condition inverse' unless nested.permission_conditions.first.permission.equal?(nested)
  user.roles << role
  if owner
    other_owner = tenant.create!(custom_keys ? { tenant_key => SecureRandom.uuid } : {})
    foreign_role = other_owner.roles.create!(name: 'Foreign')
    foreign_role.permissions.create!(model: 'Document', action: 'read')
    user.roles << foreign_role
    raise 'foreign role included' unless Writ::Configuration.roles_for(user).pluck(:id) == [role.id]
    raise 'foreign permission included' if Writ::Configuration.permissions_for(user).where(role_id: foreign_role.id).exists?
    foreign_role.destroy!
    other_owner.destroy!
  end
  access = Writ::Access
  raise 'wrong authorization' unless access.filter(context: user, action: :read, records: document).pluck(:id) == [own.id]
  raise 'wrong fields' unless access.readable_fields(context: user, record: own) == ['name']
  raise 'wrong nested authorization' unless access.filter(context: user, action: :update, records: document).pluck(:id) == [own.id]
  role.destroy!
  raise 'membership survived' unless user.roles.reload.empty?
  raise 'grant survived' unless Writ::Configuration.permission_class.count.zero?
  if owner
    other = owner.roles.create!(name: 'Other')
    user.roles << other
    owner.update!(default_user_role: other)
    owner.destroy!
    raise 'tenant memberships survived' unless user.roles.reload.empty?
    connection.execute('SET CONSTRAINTS ALL IMMEDIATE')
  end
  raise 'host role changed' if existing_role && existing_role.reload.name != 'Unrelated host role'
  puts 'GENERATED_HOST_OK' 
  raise ActiveRecord::Rollback
end
