# Run README definitions against real generated models in a rollback-only schema.
require 'active_support/all'
require 'active_record'
require 'rails_writ'
require 'rails_writ/pundit' if ARGV[2].start_with?('pundit')

directory, tenancy, integration = ARGV
multi_tenant = tenancy == 'true'
ActiveRecord::Base.establish_connection(ENV.fetch('DATABASE_URL', 'postgresql:///writ_test'))
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end
class User < ApplicationRecord; end
class Organisation < ApplicationRecord; end
class Asset < ApplicationRecord; end
class Vehicle < ApplicationRecord; end
class Truck < Vehicle; end
class Van < Vehicle; end

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
  connection.create_table(:vehicles) do |table|
    table.string :type
    table.bigint :owner_id
    table.bigint :organisation_id if multi_tenant
    table.string :name
    table.string :status
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
  snippet = ->(text) { snippets.find { |code| code.include?(text) } || abort("Missing README example: #{text}") }
  if multi_tenant
    class Current < ActiveSupport::CurrentAttributes
      attribute :organisation
    end
    eval(snippet.call('config.scoping_model = "Organisation"'), TOPLEVEL_BINDING, 'README.md')
    eval(snippet.call('config.default_role_name = "Member"'), TOPLEVEL_BINDING, 'README.md')
  end
  default = snippet.call('default_scope model: Asset do')
  if integration == 'pundit'
    class ApplicationPolicy < Writ::Pundit::Policy; end
    policy = snippet.call('  role :Member do')
    policy = policy.sub('  role :Member do', default.sub('model: Asset ', '') + "\n  role :Member do") if multi_tenant
    eval(policy, TOPLEVEL_BINDING, 'README.md')
  else
    abort 'adapter loaded in core example' if integration == 'core' && defined?(::Pundit)
    definitions = "Writ.configure do\n" + snippet.call('scope :owned, model: Asset do') +
                  snippet.call('with_options model: Asset, role: :Member')
    definitions += default if multi_tenant
    eval(definitions + "\nend", TOPLEVEL_BINDING, 'README.md')
    if integration == 'pundit_core'
      class ApplicationPolicy < Writ::Pundit::Policy; end
      eval(snippet.call("class AssetPolicy < ApplicationPolicy\nend"), TOPLEVEL_BINDING, 'README.md')
    end
  end

  model_option = integration == 'pundit' ? '' : ', model: Vehicle'
  vehicle_rules = <<~RUBY
    scope :fleet_owned#{model_option} do
      query { |context:| Vehicle.where(owner_id: context.id) }
      validate do |vehicle, errors, context:|
        errors.add(:owner_id, :not_permitted) unless vehicle.owner_id == context.id
      end
    end

    scope :fleet_status#{model_option}, arguments: { statuses: { type: :array, required: true } } do
      query { |arguments:| Vehicle.where(status: arguments.fetch(:statuses)) }
      validate do |vehicle, errors, arguments:|
        errors.add(:status, :not_permitted) unless arguments.fetch(:statuses).include?(vehicle.status)
      end
    end

    #{integration == 'pundit' ? 'role :Member' : 'with_options model: Vehicle, role: :Member'} do
      permission :read, scopes: [:fleet_owned, { fleet_status: { statuses: ['draft'] } }]
      permission :create, scopes: [:fleet_owned, { fleet_status: { statuses: ['draft'] } }]
      permission :update, scopes: [:fleet_owned, { fleet_status: { statuses: ['draft'] } }]
      accessible_fields [:name, :type, :status], action: :read
      accessible_fields #{([:name, :type, :status, :owner_id] + (multi_tenant ? [:organisation_id] : [])).inspect}, action: :update
    end
  RUBY
  if multi_tenant
    vehicle_rules += <<~RUBY
      default_scope#{integration == 'pundit' ? '' : ' model: Vehicle'} do
        query { |context:| Vehicle.where(organisation_id: Writ::Configuration.tenant_for(context).id) }
        validate do |vehicle, errors, context:|
          unless vehicle.organisation_id == Writ::Configuration.tenant_for(context).id
            errors.add(:organisation_id, :not_permitted)
          end
        end
      end
    RUBY
  end
  if integration == 'pundit'
    eval(<<~RUBY, TOPLEVEL_BINDING, __FILE__)
      class VehiclePolicy < ApplicationPolicy
        #{vehicle_rules}
      end
      class TruckPolicy < VehiclePolicy
        role :Member do
          permission :delete, scopes: [:fleet_owned]
        end
      end
      class VanPolicy < VehiclePolicy
      end
    RUBY
  else
    eval(<<~RUBY, TOPLEVEL_BINDING, __FILE__)
      Writ.configure do
        inherit_rules model: Truck, from: Vehicle
        inherit_rules model: Van, from: Vehicle
        #{vehicle_rules}
        permission :delete, model: Truck, role: :Member, scopes: [:fleet_owned]
      end
    RUBY
    if integration == 'pundit_core'
      class VehiclePolicy < ApplicationPolicy; end
      class TruckPolicy < VehiclePolicy; end
      class VanPolicy < VehiclePolicy; end
    end
  end
  Writ::Pundit::Policy.register_policy_inheritances! if integration.start_with?('pundit')
  Writ::Configuration.validate_references!

  user = User.create!
  other_user = User.create!
  organisation = Organisation.create! if multi_tenant
  other_organisation = Organisation.create! if multi_tenant
  Writ::Generator.generate_default_permissions unless multi_tenant
  roles = multi_tenant ? organisation.roles : Role.all
  if multi_tenant
    abort 'default role missing' unless organisation.default_user_role == roles.find_by!(name: 'Member')
    abort 'role assigned implicitly' if user.roles.exists?
  end
  user.roles << roles.find_by!(name: 'Member')
  # Holding another tenant's role must not broaden this context's grants.
  user.roles << other_organisation.roles.find_by!(name: 'Member') if multi_tenant
  Current.organisation = organisation if multi_tenant
  context = user
  if multi_tenant
    expected_roles = [roles.find_by!(name: 'Member').id]
    abort 'foreign roles included' unless Writ::Configuration.roles_for(user).pluck(:id) == expected_roles
    permission_roles = Writ::Configuration.permissions_for(user).distinct.pluck(:role_id)
    abort 'foreign grants included' unless permission_roles == expected_roles
  end
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
  if integration.start_with?('pundit')
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

  member = roles.find_by!(name: 'Member')
  vehicle_grants = member.permissions.where(model: 'Vehicle').order(:action).pluck(:action)
  abort 'parent grants duplicated or missing' unless vehicle_grants == %w[create read update]
  abort 'empty child grants duplicated' if member.permissions.where(model: 'Van').exists?
  truck_grant = member.permissions.find_by!(model: 'Truck', action: 'delete')
  abort 'scope owner was not preserved' unless truck_grant.scope_records.pluck(:model, :name) == [['Vehicle', 'fleet_owned']]

  vehicle_attributes = { owner_id: user.id, name: 'Delivery', status: 'draft' }
  vehicle_attributes[:organisation_id] = organisation.id if multi_tenant
  truck = Truck.create!(vehicle_attributes)
  van = Van.create!(vehicle_attributes)
  Truck.create!(vehicle_attributes.merge(owner_id: other_user.id))
  Van.create!(vehicle_attributes.merge(status: 'archived'))
  Truck.create!(vehicle_attributes.merge(organisation_id: other_organisation.id)) if multi_tenant
  expected_vehicle_ids = [truck.id, van.id].sort
  filtered_ids = access.filter(context: context, action: :read, records: Vehicle).order(:id).pluck(:id)
  abort 'inherited fleet filter' unless filtered_ids == expected_vehicle_ids
  abort 'child grant missing' unless access.authorization(context: context, action: :delete, subject: truck).allowed?
  abort 'sibling gained child grant' if access.authorization(context: context, action: :delete, subject: van).allowed?
  field_map = access.fields_for_many(context: context, action: :read, records: [truck, van])
  abort 'inherited mixed fields' unless field_map.values.all? { |fields| fields.sort == %w[name status type] }
  update_fields = %w[name owner_id status type]
  update_fields << 'organisation_id' if multi_tenant
  abort 'inherited update fields' unless access.input_fields(context: context, record: truck, action: :update).sort == update_fields.sort

  rejected_inputs = [{ type: 'Van', owner_id: other_user.id }, { type: 'Van', status: 'archived' }]
  rejected_inputs << { type: 'Van', organisation_id: other_organisation.id } if multi_tenant
  rejected_inputs.each do |input|
    proposal = access.propose(context: context, subject: Truck.find(truck.id), attributes: input)
    field = (input.keys - [:type]).first
    unless proposal.record.is_a?(Van) && proposal.record.id == truck.id && !proposal.result.allowed? &&
           proposal.result.errors.any? { |error| error.attribute == field }
      abort "inherited proposal boundary failed for #{field}"
    end
    abort 'rejected proposal was saved' unless Vehicle.find(truck.id).is_a?(Truck)
  end

  if integration.start_with?('pundit')
    abort 'adapter inherited read' unless Pundit.authorize(context, truck, :show?) == truck
    abort 'adapter inherited filter' unless Pundit.policy_scope!(context, Vehicle).order(:id).pluck(:id) == expected_vehicle_ids
    policy_fields = Pundit.policy!(context, truck).permitted_attributes_for_update.map(&:to_s)
    abort 'adapter inherited fields' unless policy_fields.sort == update_fields.sort
    controller = Class.new do
      include Pundit::Authorization
      attr_accessor :actor
      def pundit_user = actor
    end.new
    controller.actor = context
    rejected_inputs.each do |input|
      begin
        controller.send(:authorize_proposed!, Truck.find(truck.id), attributes: input)
        abort 'adapter allowed rejected conversion'
      rescue Writ::Pundit::ProposedAuthorizationError => error
        field = (input.keys - [:type]).first
        unless error.record.is_a?(Van) && error.record.id == truck.id && error.record.errors.of_kind?(field, :not_permitted)
          abort "adapter lost proposed record or #{field} errors"
        end
      end
    end
    converted = controller.send(:authorize_proposed!, Truck.find(truck.id), attributes: { type: 'Van', name: 'Converted' })
  else
    proposal = access.propose(context: context, subject: Truck.find(truck.id), attributes: { type: 'Van', name: 'Converted' })
    abort 'core conversion denied' unless proposal.result.allowed?
    converted = proposal.record
  end
  abort 'conversion lost identity' unless converted.is_a?(Van) && converted.id == truck.id && converted.persisted?
  abort 'conversion saved early' unless Vehicle.find(truck.id).is_a?(Truck)
  converted.save!
  stored = Vehicle.find(truck.id)
  abort 'conversion saved wrong subtype' unless stored.is_a?(Van) && stored.name == 'Converted'
  abort 'adapter loaded by inherited core workflow' if integration == 'core' && defined?(::Pundit)
  puts 'DOCUMENTED_WORKFLOW_OK'
  raise ActiveRecord::Rollback
end
