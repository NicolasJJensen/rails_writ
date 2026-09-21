require 'rails_helper'
require 'tmpdir'
require 'generators/writ/policy/policy_generator'
require 'generators/writ/application_policy/application_policy_generator'
require 'generators/writ/initializer/initializer_generator'
require 'generators/writ/migrations/migrations_generator'
require 'generators/writ/models/models_generator'

RSpec.describe 'Generated host code' do
  it 'generates valid Ruby for role names containing spaces' do
    Dir.mktmpdir do |dir|
      Writ::Generators::PolicyGenerator.start(['Asset', '--roles', 'Default Role'], destination_root: dir)
      expect { RubyVM::InstructionSequence.compile(File.read(File.join(dir, 'app/policies/asset_policy.rb'))) }.not_to raise_error
    end
  end

  it 'generates an ApplicationPolicy with explicit CRUD predicates' do
    Dir.mktmpdir do |dir|
      Writ::Generators::ApplicationPolicyGenerator.start([], destination_root: dir)
      source = File.read(File.join(dir, 'app/policies/application_policy.rb'))

      expect(source).to include('def read?')
      expect(source).to include('def create?')
      expect(source).to include('def update?')
      expect(source).to include('def delete?')
      expect(source).to include('Access.authorization')
      expect(source).to include('Access.filter')
      expect(source).not_to include('def method_missing')
      expect(source).not_to include('def respond_to_missing?')
      expect { RubyVM::InstructionSequence.compile(source) }.not_to raise_error
    end
  end

  it 'generates the Conditions dependency when generating ApplicationPolicy alone' do
    Dir.mktmpdir do |dir|
      Writ::Generators::ApplicationPolicyGenerator.start([], destination_root: dir)

      expect(File).to exist(File.join(dir, 'app/policies/concerns/conditions.rb'))
      expect(File.read(File.join(dir, 'app/policies/application_policy.rb'))).to include('include Conditions')
    end
  end

  it 'preserves an existing customized Conditions concern' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app/policies/concerns/conditions.rb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "module Conditions\n  CUSTOM = true\nend\n")

      Writ::Generators::ApplicationPolicyGenerator.start([], destination_root: dir)

      expect(File.read(path)).to include('CUSTOM = true')
    end
  end

  it 'documents host permission and role sources in the generated initializer' do
    Dir.mktmpdir do |dir|
      Writ::Generators::InitializerGenerator.start([], destination_root: dir)
      source = File.read(File.join(dir, 'config/initializers/writ.rb'))

      expect(source).to include('config.permission_source = ->(context) { context.permissions_for_current_tenant }')
      expect(source).to include('config.role_source = ->(context) { context.roles_for_current_tenant }')
      expect(source).to include('does not infer tenant ownership')
      expect(source).to include(':warning          - log and skip only that missing proposed-state matcher')
      expect(source).to include('Keep :raise while policy definitions are expected to be complete')
    end
  end

  it 'dispatches generated CRUD and custom predicates and rejects unknown or invalid calls' do
    Dir.mktmpdir do |dir|
      Writ::Generators::ApplicationPolicyGenerator.start([], destination_root: dir)
      Writ::Generators::PolicyGenerator.start(
        ['Asset', '--roles', 'Admin', '--actions', 'read', 'create', 'update', 'delete', 'approve'],
        destination_root: dir
      )

      stub_const('GeneratedPolicyContract', Module.new)
      GeneratedPolicyContract.const_set(:Conditions, Module.new)
      GeneratedPolicyContract.const_set(:Asset, ::Asset)
      base_source = File.read(File.join(dir, 'app/policies/application_policy.rb'))
      policy_source = File.read(File.join(dir, 'app/policies/asset_policy.rb'))
      eval(
        "module GeneratedPolicyContract\n#{base_source}\n#{policy_source}\nend",
        TOPLEVEL_BINDING,
        File.join(dir, 'app/policies/asset_policy.rb')
      )

      context = Object.new
      record = Object.new
      context_object = context
      record_object = record
      allow(Writ::Access).to receive(:authorization) do |context:, action:, subject:|
        expect(context).to equal(context_object)
        expect(subject).to equal(record_object)
        instance_double('Decision', allowed?: action)
      end
      policy = GeneratedPolicyContract::AssetPolicy.new(context, record)

      expect(policy.read?).to eq(:read)
      expect(policy.create?).to eq(:create)
      expect(policy.update?).to eq(:update)
      expect(policy.delete?).to eq(:delete)
      expect(policy.approve?).to eq(:approve)
      expect { policy.typo? }.to raise_error(NoMethodError)
      expect { policy.read?(:unexpected) }.to raise_error(ArgumentError)
    end
  end

  it 'uses class-grant create authorization for a new record in the generated policy' do
    Dir.mktmpdir do |dir|
      Writ::Generators::ApplicationPolicyGenerator.start([], destination_root: dir)
      Writ::Generators::PolicyGenerator.start(['Asset', '--roles', 'Admin'], destination_root: dir)
      stub_const('GeneratedCreatePolicyContract', Module.new)
      GeneratedCreatePolicyContract.const_set(:Conditions, Module.new)
      GeneratedCreatePolicyContract.const_set(:Asset, ::Asset)
      base_source = File.read(File.join(dir, 'app/policies/application_policy.rb'))
      policy_source = File.read(File.join(dir, 'app/policies/asset_policy.rb'))
      eval("module GeneratedCreatePolicyContract\n#{base_source}\n#{policy_source}\nend", TOPLEVEL_BINDING,
           File.join(dir, 'app/policies/asset_policy.rb'))

      organisation = create(:organisation)
      role = create(:role, organisation: organisation)
      context = Struct.new(:permissions).new(role.permissions)
      proposed = Asset.new(organisation: organisation)
      original_registry = Writ::Configuration.registry
      Writ::Configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
      policy = GeneratedCreatePolicyContract::AssetPolicy.new(context, proposed)

      expect(policy.create?).to be(false)

      Writ::Configuration.register_condition(name: 'generated_create_gate') { false }
      create(:permission, role: role, action: :create, conditions: ['generated_create_gate'])
      expect(policy.create?).to be(false)

      role.permissions.destroy_all
      create(:permission, role: role, action: :create)
      validator_calls = 0
      Writ::Configuration.register_creation_validator(model_name: 'Asset') do |context:, record:|
        validator_calls += 1
        false
      end
      expect(policy.create?).to be(true)
      expect(Writ::Access.validation(context: context, action: :create, subject: proposed)).not_to be_allowed
      expect(validator_calls).to eq(1)
    ensure
      Writ::Configuration.instance_variable_set(:@registry, original_registry) if original_registry
    end
  end

  it 'targets Rails join table names for a custom role holder' do
    Dir.mktmpdir do |dir|
      Writ::Generators::MigrationsGenerator.start(['--roleable-model=Account'], destination_root: dir)
      path = Dir[File.join(dir, 'db/migrate/*join_table*')].first
      expect(File.read(path)).to include('create_table :accounts_roles, id: false')
    end
  end

  %w[review_auth_accounts accounts].each do |actor_table|
  it "uses Rails membership inference for #{actor_table} and a namespaced role" do
    stub_const('ReviewAuth::Account', Class.new(ActiveRecord::Base) do
      self.table_name = actor_table
    end)
    stub_const('ReviewAuth::Role', Class.new(ActiveRecord::Base) { self.table_name = 'review_auth_roles' })
    ReviewAuth::Account.has_and_belongs_to_many :roles, class_name: 'ReviewAuth::Role'
    expected_table = ReviewAuth::Account.reflect_on_association(:roles).join_table
    Dir.mktmpdir do |dir|
      options = ['--roleable-model=ReviewAuth::Account', '--model-namespace=ReviewAuth']
      Writ::Generators::MigrationsGenerator.start(options, destination_root: dir)
      Writ::Generators::ModelsGenerator.start(options, destination_root: dir)

      path = Dir[File.join(dir, 'db/migrate/*join_table*')].first
      expect(File.read(path)).to include("create_table :#{expected_table}, id: false")
      expect(File.read(File.join(dir, 'app/models/review_auth/role.rb'))).not_to include('join_table:')
    end
  end
  end

  it 'rejects invalid policy actions before writing a policy' do
    Dir.mktmpdir do |dir|
      expect do
        Writ::Generators::PolicyGenerator.start(
          ['Asset', '--roles', 'Admin', '--actions', 'bad-action'], destination_root: dir
        )
      end.to raise_error(ArgumentError, /Invalid action/)
      expect(Dir[File.join(dir, '**/*')]).to be_empty
    end
  end

  it 'rejects custom actions that collide with CRUD predicate aliases' do
    Dir.mktmpdir do |dir|
      %w[show permitted respond_to is_a].each do |action|
        expect do
          Writ::Generators::PolicyGenerator.start(
            ['Asset', '--roles', 'Admin', '--actions', action], destination_root: dir
          )
        end.to raise_error(ArgumentError, /Reserved policy action/)
      end
      expect(Dir[File.join(dir, '**/*')]).to be_empty
    end
  end

  it 'keeps ordinary custom predicates while preserving policy introspection' do
    Dir.mktmpdir do |dir|
      Writ::Generators::PolicyGenerator.start(
        ['Asset', '--roles', 'Admin', '--actions', 'approve'], destination_root: dir
      )
      source = File.read(File.join(dir, 'app/policies/asset_policy.rb'))
      expect(source).to include('def approve?')
      expect(source).not_to include('def respond_to?')
      expect(source).not_to include('def is_a?')
    end
  end

  it 'uses explicit UUID host key types and custom primary-key columns in migrations and associations' do
    Dir.mktmpdir do |dir|
      options = [
        '--roleable-model=Account', '--multi-tenant', '--scoping-model=Organisation',
        '--roleable-primary-key=account_number', '--roleable-primary-key-type=uuid',
        '--scoping-primary-key=organisation_uuid', '--scoping-primary-key-type=uuid'
      ]
      Writ::Generators::MigrationsGenerator.start(options, destination_root: dir)
      Writ::Generators::ModelsGenerator.start(options, destination_root: dir)

      join = File.read(Dir[File.join(dir, 'db/migrate/*join_table*')].first)
      roles = File.read(Dir[File.join(dir, 'db/migrate/*create_roles*')].first)
      role = File.read(File.join(dir, 'app/models/role.rb'))

      expect(join).to include('t.uuid :account_id')
      expect(join).to include('primary_key: "account_number"')
      expect(roles).to include('type: :uuid')
      expect(roles).to include('primary_key: "organisation_uuid"')
      expect(roles).to include('unique: true')
      expect(roles).to include('tenant_name')
      expect(roles).not_to include('IS NULL')
      expect(role).to include('primary_key: "organisation_uuid"')
    end
  end

  it 'keeps the global name uniqueness index for single-tenant migrations' do
    Dir.mktmpdir do |dir|
      Writ::Generators::MigrationsGenerator.start([], destination_root: dir)
      roles = File.read(Dir[File.join(dir, 'db/migrate/*create_roles*')].first)

      expect(roles).to include('add_index :roles, :name, unique: true')
      expect(roles).not_to include('IS NULL')
    end
  end

  it 'rejects unsafe explicit key options before writing migrations' do
    Dir.mktmpdir do |dir|
      expect do
        Writ::Generators::MigrationsGenerator.start(
          ['--roleable-primary-key-type=uuid;drop_table(:users)'], destination_root: dir
        )
      end.to raise_error(ArgumentError, /primary_key_type/)
      expect(Dir[File.join(dir, '**/*')]).to be_empty
    end
  end

  it 'infers bigint width from a loaded host model' do
    Dir.mktmpdir do |dir|
      Writ::Generators::MigrationsGenerator.start(['--roleable-model=User'], destination_root: dir)
      join = File.read(Dir[File.join(dir, 'db/migrate/*join_table*')].first)
      expect(join).to include('t.bigint :user_id')
    end
  end

  it 'infers the type of a loaded custom primary-key column' do
    stub_const('GeneratorKeyAccount', Class.new(ActiveRecord::Base) do
      self.table_name = 'assets'
      self.primary_key = 'name'
    end)
    Dir.mktmpdir do |dir|
      Writ::Generators::MigrationsGenerator.start(['--roleable-model=GeneratorKeyAccount'], destination_root: dir)
      join = File.read(Dir[File.join(dir, 'db/migrate/*join_table*')].first)
      expect(join).to include('t.string :generator_key_account_id', 'primary_key: "name"')
    end
  end

  it 'rejects composite host keys before writing any generated files' do
    stub_const('GeneratorCompositeAccount', Class.new(ActiveRecord::Base) do
      self.table_name = 'assets'
      self.primary_key = %w[id organisation_id]
    end)
    Dir.mktmpdir do |dir|
      expect do
        Writ::Generators::MigrationsGenerator.start(['--roleable-model=GeneratorCompositeAccount'], destination_root: dir)
      end.to raise_error(ArgumentError, /single-column/)
      expect(Dir[File.join(dir, '**/*')]).to be_empty
    end
  end

  it 'supports a conventional loaded host whose table has not been migrated yet' do
    stub_const('GeneratorPendingAccount', Class.new(ActiveRecord::Base) { self.table_name = 'not_created_accounts' })
    Dir.mktmpdir do |dir|
      expect do
        Writ::Generators::MigrationsGenerator.start(['--roleable-model=GeneratorPendingAccount'], destination_root: dir)
      end.not_to raise_error
      join = File.read(Dir[File.join(dir, 'db/migrate/*join_table*')].first)
      expect(join).to include('t.bigint :generator_pending_account_id', 'primary_key: "id"')
    end
  end
end
