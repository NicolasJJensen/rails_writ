# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Host proposed-write responses' do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:role) { create(:role, organisation: organisation, accessible_fields: { 'Asset' => ['name'] }) }
  let(:record) { create(:asset, organisation: organisation, name: 'Allowed') }

  around do |example|
    original = Writ::Configuration.registry
    Writ::Configuration.instance_variable_set(:@registry, Writ::Logic::Registry.new)
    user.roles << role
    Writ::DSL::ConfigurationDSL.new(Writ::Configuration).scope(:named, model: Asset) do
      query { Asset.all }
      validate do |candidate, errors|
        errors.add(:name, :invalid, message: 'must start with A') unless candidate.name.start_with?('A')
      end
    end
    example.run
  ensure
    Writ::Configuration.instance_variable_set(:@registry, original)
  end

  before do
    stub_const('ProposedResponseController', Class.new(ActionController::Base) do
      include Pundit::Authorization
      after_action :verify_authorized
      rescue_from Pundit::NotAuthorizedError, with: :forbidden
      rescue_from Writ::Pundit::ProposedAuthorizationError, with: :invalid_proposal

      def pundit_user
        User.find(request.headers.fetch('X-User-Id'))
      end

      def update
        @asset = authorize(Asset.find(params[:id]), :update?)
        authorize_proposed!(@asset, attributes: permitted_attributes(@asset, :update))
        @asset.save!
        head :no_content
      end

      private

      def forbidden
        head :forbidden
      end

      def invalid_proposal(error)
        if request.format.json?
          render json: { errors: error.record.errors.to_hash }, status: :unprocessable_entity
        else
          form = helpers.form_with(model: error.record, url: '/assets') do |builder|
            builder.text_field(:name) + helpers.tag.span(error.record.errors[:name].join(', '))
          end
          if request.headers['Accept'] == 'text/vnd.turbo-stream.html'
            render body: helpers.tag.turbo_stream(helpers.tag.template(form), action: 'replace', target: 'asset_form'),
                   content_type: 'text/vnd.turbo-stream.html', status: :unprocessable_entity
          else
            render html: form, status: :unprocessable_entity
          end
        end
      end
    end)
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { patch '/assets/:id', to: 'proposed_response#update' }
    @session = ActionDispatch::Integration::Session.new(routes)
  end

  def submit(name, accept: 'text/html')
    @session.patch("/assets/#{record.id}", params: { asset: { name: name } },
                   headers: { 'X-User-Id' => user.id.to_s, 'Accept' => accept })
    @session.response
  end

  it 'returns 403 before assignment when saved-state authority is missing' do
    response = submit('Bad')
    expect(response.status).to eq(403)
    expect(record.reload.name).to eq('Allowed')
  end

  it 'rerenders submitted values and inline model errors as HTML with 422' do
    create(:permission, role: role, action: :update, scopes: ['named'])
    response = submit('Bad')
    expect(response.status).to eq(422)
    expect(response.body).to include('value="Bad"', 'must start with A', 'field_with_errors')
    expect(record.reload.name).to eq('Allowed')
  end

  it 'lets the host return a Turbo form replacement with the same errors and 422' do
    create(:permission, role: role, action: :update, scopes: ['named'])
    response = submit('Bad', accept: 'text/vnd.turbo-stream.html')
    expect(response.status).to eq(422)
    expect(response.media_type).to eq('text/vnd.turbo-stream.html')
    expect(response.body).to include('<turbo-stream', 'target="asset_form"', 'value="Bad"', 'must start with A')
  end

  it 'returns attribute errors as JSON with 422 and saves only an accepted retry' do
    create(:permission, role: role, action: :update, scopes: ['named'])
    response = submit('Bad', accept: 'application/json')
    expect(response.status).to eq(422)
    expect(JSON.parse(response.body)).to eq('errors' => { 'name' => ['must start with A'] })
    expect(record.reload.name).to eq('Allowed')
    expect(submit('Accepted', accept: 'application/json').status).to eq(204)
    expect(record.reload.name).to eq('Accepted')
  end
end
