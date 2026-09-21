require 'rails_helper'
require 'open3'

RSpec.describe Writ::Logic::ArgumentValidator do
  describe ".validate_schema!" do
    it "accepts a valid schema" do
      expect {
        described_class.validate_schema!({ ids: { type: :array, required: true, max_length: 5 } }, "scope 'x'")
      }.not_to raise_error
    end

    it "accepts an empty/nil schema" do
      expect { described_class.validate_schema!({}, "scope 'x'") }.not_to raise_error
      expect { described_class.validate_schema!(nil, "scope 'x'") }.not_to raise_error
    end

    it "rejects empty schemas that are not Hashes" do
      expect { described_class.validate_schema!([], "scope 'x'") }
        .to raise_error(ArgumentError, /must be a Hash/)
      expect { described_class.validate_schema!("", "condition 'x'") }
        .to raise_error(ArgumentError, /must be a Hash/)
    end

    it "rejects an invalid type" do
      expect {
        described_class.validate_schema!({ ids: { type: :money } }, "scope 'x'")
      }.to raise_error(ArgumentError, /invalid type/)
    end

    it "rejects unknown schema keys" do
      expect {
        described_class.validate_schema!({ ids: { type: :array, bogus: true } }, "scope 'x'")
      }.to raise_error(ArgumentError, /unknown key/)
    end

    it "rejects a default that violates its declared type" do
      expect {
        described_class.validate_schema!({ ids: { type: :array, default: "not-an-array" } }, "scope 'x'")
      }.to raise_error(ArgumentError, /default.*invalid/)
    end

    it "rejects a non-integer max_length" do
      expect {
        described_class.validate_schema!({ ids: { type: :array, max_length: "5" } }, "scope 'x'")
      }.to raise_error(ArgumentError, /max_length.*Integer/)
    end

    it "rejects a negative max_length" do
      expect {
        described_class.validate_schema!({ ids: { type: :array, max_length: -1 } }, "scope 'x'")
      }.to raise_error(ArgumentError, /max_length.*non-negative/)
    end

    it "requires required to be a boolean when supplied" do
      expect {
        described_class.validate_schema!({ ids: { type: :array, required: "yes" } }, "scope 'x'")
      }.to raise_error(ArgumentError, /required.*boolean/)
    end

    it "rejects duplicate normalized argument keys" do
      expect {
        described_class.validate_schema!(
          { foo: { type: :string }, 'foo' => { type: :integer } },
          "scope 'x'"
        )
      }.to raise_error(ArgumentError, /duplicate.*foo/i)
    end

    it "rejects duplicate normalized option keys" do
      conflicting_options = {
        type: { type: :array, 'type' => :array },
        required: { type: :array, required: true, 'required' => false },
        default: { type: :array, default: [], 'default' => [1] },
        max_length: { type: :array, max_length: 5, 'max_length' => 6 }
      }

      conflicting_options.each do |option, spec|
        expect {
          described_class.validate_schema!({ value: spec }, "scope 'x'")
        }.to raise_error(ArgumentError, /duplicate.*#{option}/i)
      end
    end

    it "accepts schemas whose option keys are consistently symbols or strings" do
      expect {
        described_class.validate_schema!(
          { symbols: { type: :array, required: true, default: [], max_length: 5 } },
          "scope 'x'"
        )
      }.not_to raise_error

      expect {
        described_class.validate_schema!(
          { strings: { 'type' => :array, 'required' => true, 'default' => [], 'max_length' => 5 } },
          "scope 'x'"
        )
      }.not_to raise_error
    end
  end

  describe ".validate! / .errors_for" do
    let(:schema) { { ids: { type: :array, required: true }, limit: { type: :integer, default: 10 } } }

    it "returns a HashWithIndifferentAccess with defaults applied" do
      result = described_class.validate!(schema: schema, arguments: { "ids" => [1, 2] }, label: "scope 'x'")
      expect(result).to be_a(ActiveSupport::HashWithIndifferentAccess)
      expect(result[:ids]).to eq([1, 2])
      expect(result[:limit]).to eq(10)
    end

    it "reads via symbol or string keys interchangeably" do
      result = described_class.validate!(schema: schema, arguments: { ids: [9] }, label: "scope 'x'")
      expect(result["ids"]).to eq([9])
      expect(result[:ids]).to eq([9])
    end

    it "raises listing every problem at once" do
      expect {
        described_class.validate!(schema: schema, arguments: { "ids" => "nope", "bogus" => 1 }, label: "scope 'x'")
      }.to raise_error(Writ::InvalidArgumentsError) do |e|
        expect(e.message).to include("unknown argument 'bogus'")
        expect(e.message).to include("must be an array")
      end
    end

    it "reports missing required arguments" do
      errors = described_class.errors_for(schema: schema, arguments: {})
      expect(errors).to include("missing required argument 'ids'")
    end

    it "enforces max_length" do
      errors = described_class.errors_for(
        schema: { ids: { type: :array, max_length: 2 } },
        arguments: { ids: [1, 2, 3] }
      )
      expect(errors).to include(/exceeds max_length 2/)
    end

    it "enforces integer and boolean types" do
      expect(described_class.errors_for(schema: { n: { type: :integer } }, arguments: { n: "x" })).to include(/must be an integer/)
      expect(described_class.errors_for(schema: { b: { type: :boolean } }, arguments: { b: "x" })).to include(/must be a boolean/)
    end

    it "does not coerce array element types (left to ActiveRecord)" do
      errors = described_class.errors_for(schema: { ids: { type: :array } }, arguments: { ids: %w[1 2] })
      expect(errors).to be_empty
    end

    it "loads HashWithIndifferentAccess for a standalone validator require" do
      root = File.expand_path('../../../../', __dir__)
      script = <<~'RUBY'
        require 'writ/logic/argument_validator'
        result = Writ::Logic::ArgumentValidator.errors_for(schema: {}, arguments: {})
        abort "unexpected errors: #{result.inspect}" unless result.empty?
      RUBY

      _output, status = Open3.capture2e({ 'RUBYLIB' => File.join(root, 'lib') }, 'ruby', '-e', script)
      expect(status).to be_success
    end
  end
end
