require 'rails_helper'
require 'tmpdir'
require 'generators/writ/roleable/roleable_generator'

RSpec.describe 'Second review regressions' do
  let(:config) { Writ::Configuration }
  let(:access) { Writ::Access }
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation) }
  let(:context) { Struct.new(:permissions).new(role.permissions) }

  around do |example|
    original = config.registry
    modes = [config.on_invalid_scope_arguments, config.on_invalid_condition_arguments]
    example.run
  ensure
    config.instance_variable_set(:@registry, original)
    config.on_invalid_scope_arguments, config.on_invalid_condition_arguments = modes
    %w[review_scope review_optional].each { |name| original.remove_scope_callable(model_name: 'Asset', scope_name: name) }
    original.remove_condition(name: 'review_condition')
    Current.reset
  end

  before { Current.user = create(:user, organisation: organisation) }

  { scopes: %w[status_active current_location created], conditions: %w[business_hours weekdays_only weekends_only] }.each do |kind, names|
    it "replaces #{kind} from a stale loaded association" do
      permission = create(:permission, role: role, kind => [names[0]])
      permission.public_send("permission_#{kind}").load
      Permission.find(permission.id).update!(kind => [names[1]])
      permission.update!(kind => [names[2]])
      expect(permission.reload.public_send(kind)).to eq([names[2]])
    end
  end

  it 'removes model default pagination from all authorization branches' do
    table_name = "review_assets_#{SecureRandom.hex(6)}"
    connection = ActiveRecord::Base.connection
    connection.create_table(table_name) do |t|
      t.string :name, null: false
      t.bigint :organisation_id, null: false
      t.bigint :location_id
      t.text :description
      t.integer :status
      t.boolean :archived, null: false, default: false
      t.timestamps null: false
    end
    stub_const('ReviewAsset', Class.new(ActiveRecord::Base) do
      self.table_name = table_name
      default_scope { where(archived: false).order(:id).limit(1).offset(1) }
    end)
    first = ReviewAsset.create!(name: 'First', organisation_id: organisation.id)
    second = ReviewAsset.create!(name: 'Second', organisation_id: organisation.id)
    ReviewAsset.create!(name: 'Archived', organisation_id: organisation.id, archived: true)
    create(:permission, role: role, model: 'ReviewAsset')
    [ReviewAsset, ReviewAsset.all].each do |records|
      expect(access.filter(context: context, action: :read, records: records).pluck(:id)).to match_array([first.id, second.id])
    end
    expect(access.authorization(context: context, action: :read, subject: ReviewAsset.unscoped.find(first.id))).to be_allowed
  ensure
    connection&.drop_table(table_name, if_exists: true)
  end

  it 'does not multiply eager-loaded rows for multiple permission annotations' do
    asset = create(:asset, organisation: organisation)
    asset.service_industries = create_list(:service_industry, 2)
    %w[read update delete].each { |action| create(:permission, role: role, action: action) }
    records = Asset.where(id: asset.id).eager_load(:service_industries)
    annotated = access.join_user_permissions_with_records(records, :read, :update, :delete, context: context)
    expect(Asset.connection.select_all(annotated.to_sql).length).to eq(2)
    expect(annotated.first.attributes).to include('can_read' => true, 'can_update' => true, 'can_delete' => true)
  end

  [:scope, :condition].each do |kind|
    it "rejects stored #{kind} arguments after schema removal" do
      name = "review_#{kind}"
      if kind == :scope
        config.register_scope(model_name: 'Asset', scope_name: name, arguments: { ids: { type: :array } }) { |_ctx, _args| Asset.all }
      else
        config.register_condition(name: name, arguments: { ids: { type: :array } }) { |_ctx, _args| true }
      end
      create(:permission, role: role, "#{kind}s" => [{ name => { ids: [1] } }])
      if kind == :scope
        config.register_scope(model_name: 'Asset', scope_name: name, replace: true) { Asset.all }
      else
        config.register_condition(name: name, replace: true) { true }
      end
      config.public_send("on_invalid_#{kind}_arguments=", :deny)
      expect(access.filter(context: context, action: :read, records: Asset)).to be_empty
      config.public_send("on_invalid_#{kind}_arguments=", :raise)
      expect { access.filter(context: context, action: :read, records: Asset) }.to raise_error(Writ::InvalidArgumentsError)
    end
  end

  it 'accepts optional positional arguments in parameterized blocks' do
    config.register_scope(model_name: 'Asset', scope_name: 'review_optional', arguments: { ids: { type: :array } }) do |_context, args = {}|
      Asset.where(id: args[:ids])
    end
    asset = create(:asset, organisation: organisation)
    create(:permission, role: role, scopes: [{ review_optional: { ids: [asset.id] } }])
    expect(access.filter(context: context, action: :read, records: Asset).pluck(:id)).to eq([asset.id])
  end

  it 'passes schema arguments when every block parameter is optional' do
    config.register_condition(name: 'review_condition', arguments: { allowed: { type: :boolean } }) do |_context = nil, args = {}|
      args[:allowed]
    end
    create(:permission, role: role, conditions: [{ review_condition: { allowed: true } }])
    expect(access.grant_available?(context: context, action: :read, model: Asset)).to be(true)
  end

  it 'injects into module-wrapped models and remains idempotent' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app/models/host/account.rb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "module Host\n  class Account < ApplicationRecord\n  end\nend\n")
      allow(Rails).to receive(:root).and_return(Pathname.new(dir))
      2.times { Writ::Generators::RoleableGenerator.start(['Host::Account'], destination_root: dir) }
      expect(File.read(path).scan('as_roleable').length).to eq(1)
      expect { RubyVM::InstructionSequence.compile(File.read(path)) }.not_to raise_error
    end
  end

  it 'recognises differently formatted roleable declarations' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app/models/host/account.rb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~RUBY)
        module Host
          class Account < ApplicationRecord
            include(
              Writ::Roleable
            )

            as_roleable(
              scoping_model: true
            )
          end
        end
      RUBY
      allow(Rails).to receive(:root).and_return(Pathname.new(dir))

      Writ::Generators::RoleableGenerator.start(
        ['Host::Account', '--scoping-model'], destination_root: dir
      )

      expect(File.read(path).scan('Writ::Roleable').length).to eq(1)
      expect(File.read(path).scan('as_roleable').length).to eq(1)
    end
  end

  %w[Writ::Roleable ::Writ::Roleable].each do |roleable_constant|
    it "keeps an existing #{roleable_constant} include idempotent" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'app/models/account.rb')
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, <<~RUBY)
          class Account < ApplicationRecord
            include #{roleable_constant}
            as_roleable
          end
        RUBY
        allow(Rails).to receive(:root).and_return(Pathname.new(dir))

        2.times { Writ::Generators::RoleableGenerator.start(['Account'], destination_root: dir) }

        source = File.read(path)
        expect(source.scan('Writ::Roleable').length).to eq(1)
        expect(source.scan('as_roleable').length).to eq(1)
      end
    end
  end

  it 'only considers declarations in the requested model class' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app/models/host/account.rb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~RUBY)
        module Host
          class Other < ApplicationRecord
            include Writ::Roleable
            as_roleable
          end

          class Account < ApplicationRecord
          end
        end
      RUBY
      allow(Rails).to receive(:root).and_return(Pathname.new(dir))

      Writ::Generators::RoleableGenerator.start(['Host::Account'], destination_root: dir)

      source = File.read(path)
      expect(source.scan('Writ::Roleable').length).to eq(2)
      expect(source.scan('as_roleable').length).to eq(2)
      expect(source).to include("class Account < ApplicationRecord\n    include Writ::Roleable\n\n    as_roleable")
    end
  end

  it 'adds only the missing declaration when the other one already exists' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app/models/account.rb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~RUBY)
        class Account < ApplicationRecord
          as_roleable(
            auto_generate: false
          )
        end
      RUBY
      allow(Rails).to receive(:root).and_return(Pathname.new(dir))

      Writ::Generators::RoleableGenerator.start(['Account'], destination_root: dir)

      source = File.read(path)
      expect(source.scan('Writ::Roleable').length).to eq(1)
      expect(source.scan('as_roleable').length).to eq(1)
      expect(source).to include('auto_generate: false')
    end
  end

  it 'adds a missing scoping declaration without changing an existing include' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app/models/organisation.rb')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~RUBY)
        class Organisation < ApplicationRecord
          include Writ::Roleable
        end
      RUBY
      allow(Rails).to receive(:root).and_return(Pathname.new(dir))

      Writ::Generators::RoleableGenerator.start(
        ['Organisation', '--scoping-model'], destination_root: dir
      )

      source = File.read(path)
      expect(source.scan('Writ::Roleable').length).to eq(1)
      expect(source.scan('as_roleable').length).to eq(1)
      expect(source).to include('as_roleable(scoping_model: true)')
    end
  end

  it 'reports a model declaration that cannot be injected' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'app/models'))
      File.write(File.join(dir, 'app/models/account.rb'), "Account = Class.new(ApplicationRecord)\n")
      allow(Rails).to receive(:root).and_return(Pathname.new(dir))
      expect do
        Writ::Generators::RoleableGenerator.new(['Account'], {}, destination_root: dir).invoke_all
      end.to raise_error(Thor::Error, /declaration.*multiline|multiline.*declaration/i)
    end
  end

  it 'recovers a catalog insert that wins before uniqueness validation' do
    config.register_scope(model_name: 'Asset', scope_name: 'review_scope') { Asset.all }
    winner = Scope.create!(model: 'Asset', name: 'review_scope')
    allow(Scope).to receive(:find_or_create_by!).and_call_original
    # Force the create branch after another writer supplied the matching catalog row.
    allow(Scope).to receive(:find_or_create_by!).with({ model: 'Asset', name: 'review_scope' }) do |attributes|
      Scope.create!(attributes)
    end
    permission = create(:permission, role: role, scopes: ['review_scope'])
    expect(permission.permission_scopes.first.scope_id).to eq(winner.id)
    expect(Scope.where(model: 'Asset', name: 'review_scope').count).to eq(1)
  end
end
