# frozen_string_literal: true

RSpec.describe Dry::Schema::Params do
  it_behaves_like "schema logic operators" do
    let(:schema_method) { :Params }
  end

  before do
    Test::UserSchema = Dry::Schema.Params do
      required(:login).filled(:string)
      required(:age).value(:integer)
    end

    Test::GuestSchema = Dry::Schema.Params do
      required(:name).filled(:string)
    end
  end

  context "with a hash that needs coercion" do
    shared_examples "nested composed schemas" do
      context "with coercion" do
        let(:result) do
          schema.(input)
        end

        context "with unexpected keys" do
          let(:input) do
            {user: {foo: "bar", login: "jane", age: 36}}
          end

          it "uses a merged key-map to sanitize keys" do
            expect(result[:user].keys).to eql(%i[login age])
          end
        end

        context "with values that need coercion" do
          let(:input) do
            {user: {login: "jane", age: "36"}}
          end

          it "uses a merged key-map to sanitize keys" do
            expect(result[:user]).to eql(login: "jane", age: 36)
          end
        end

        context "with invalid values" do
          let(:input) do
            {user: {login: "", age: "36"}}
          end

          it "builds a nested error hash" do
            expect(result.errors[:user]).to eql(
              or: [{login: ["must be filled"]}, {name: ["is missing"]}]
            )
          end
        end
      end
    end

    context "using `hash`" do
      subject(:schema) do
        Dry::Schema.Params do
          required(:user).hash(Test::UserSchema | Test::GuestSchema)
        end
      end

      include_context "nested composed schemas"
    end

    context "using `schema`" do
      subject(:schema) do
        Dry::Schema.Params do
          required(:user).schema(Test::UserSchema | Test::GuestSchema)
        end
      end

      include_context "nested composed schemas"
    end
  end

  # https://github.com/dry-rb/dry-schema/issues/444
  it "coerces and validates nested keys shared by OR branches", :aggregate_failures do
    left = Dry::Schema.Params do
      required(:options).hash { required(:limit).filled(:integer) }
      optional(:rows).array(:hash) { required(:a).filled(:integer) }
    end
    right = Dry::Schema.Params do
      required(:options).hash { required(:offset).filled(:integer) }
      optional(:rows).array(:hash) { required(:b).filled(:integer) }
    end
    schema = Dry::Schema.Params do
      config.validate_keys = true
      required(:query).schema(left | right)
    end

    [%w[limit a], %w[offset b]].each do |key, row_key|
      result = schema.call("query" => {"options" => {key => "10"}, "rows" => [{row_key => "2"}]})
      expect(result).to be_success
      expect(result.to_h).to eq(query: {options: {key.to_sym => 10}, rows: [{row_key.to_sym => 2}]})
    end
    expect(schema.call(query: {options: {other: 10}}).errors.to_h).to eq(
      query: {options: {other: ["is not allowed"]}}
    )
  end

  it "retains nullable collections and their coercion order across OR branches", :aggregate_failures do
    schema_with_rows = Dry::Schema.Params do
      required(:options).hash { required(:count).filled(:integer) }
      required(:rows).array(:hash) { required(:count).filled(:integer) }
    end
    nullable_schemas = %i[limit offset].map do |key|
      Dry::Schema.Params do
        required(:options).maybe(:hash) { required(key).filled(:integer) }
        required(:rows).maybe(:array) { each { hash { required(key).filled(:integer) } } }
      end
    end
    alternatives = nullable_schemas.reduce(:|)

    [[schema_with_rows | alternatives, []], [alternatives | schema_with_rows, nil]].each do |operation, empty_rows|
      schema = Dry::Schema.Params do
        config.validate_keys = true
        required(:query).schema(operation)
      end

      %i[count limit offset].each do |key|
        values = {key.to_s => "2"}
        result = schema.call("query" => {"options" => values, "rows" => [values]})
        expect(result).to be_success
        expect(result.to_h).to eq(query: {options: {key => 2}, rows: [{key => 2}]})
      end
      expect(schema.call(query: {options: nil, rows: nil})).to be_success
      expect(schema.call(query: {options: nil, rows: ""}).to_h).to eq(query: {options: nil, rows: empty_rows})
    end
  end

  context "with an array with hashes that need coercion" do
    context "with coercion" do
      subject(:schema) do
        Dry::Schema.Params do
          required(:sites).array(:hash, Test::UserSchema | Test::GuestSchema)
        end
      end

      let(:result) do
        schema.(input)
      end

      context "with unexpected keys" do
        let(:input) do
          {sites: [
            {foo: "bar", login: "jane", age: 36},
            {bar: "foo", login: "john", age: 25}
          ]}
        end

        it "uses a merged key-map to sanitize keys" do
          expect(result[:sites][0].keys).to eql(%i[login age])
          expect(result[:sites][1].keys).to eql(%i[login age])
        end
      end

      context "with values that need coercion" do
        let(:input) do
          {sites: [
            {login: "jane", age: "36"},
            {login: "john", age: "25"}
          ]}
        end

        it "uses a merged key-map to sanitize keys" do
          expect(result[:sites][0]).to eql(login: "jane", age: 36)
          expect(result[:sites][1]).to eql(login: "john", age: 25)
        end
      end

      context "with invalid values" do
        let(:input) do
          {sites: [
            {login: "jane", age: ""},
            {name: ""},
            {login: "", age: "25"}
          ]}
        end

        it "builds a deeply nested error hash" do
          expect(result.errors[:sites]).to eql(
            0 => {
              or: [
                {age: ["must be an integer"]},
                {name: ["is missing"]}
              ]
            },
            1 => {
              or: [
                {age: ["is missing"], login: ["is missing"]},
                {name: ["must be filled"]}
              ]
            },
            2 => {
              or: [
                {login: ["must be filled"]},
                {name: ["is missing"]}
              ]
            }
          )
        end
      end
    end
  end

  %i[and then].each do |operator|
    it "retains keys from both sides of #{operator} inside array members" do
      left = Dry::Schema.Params do
        required(:rows).array(:hash) { required(:limit).filled(:integer) }
      end
      right = Dry::Schema.Params do
        required(:rows).array(:hash) { required(:offset).filled(:integer) }
      end
      schema = Dry::Schema.Params { required(:query).schema(left.public_send(operator, right)) }

      result = schema.call("query" => {"rows" => [{"limit" => "10", "offset" => "5"}]})
      expect(result).to be_success
      expect(result.to_h).to eq(query: {rows: [{limit: 10, offset: 5}]})

      errors = schema.call(query: {rows: [{limit: 10}]}).errors.to_h
      expect(errors).to eq(query: {rows: {0 => {offset: ["is missing"]}}})
    end

    it "preserves nil coercion when both sides of #{operator} are optional" do
      left = Dry::Schema.Params { required(:value).maybe(:integer) }
      right = Dry::Schema.Params { required(:value).maybe(Types::Params::Integer.constrained(gteq: 0)) }
      schema = Dry::Schema.Params { required(:item).schema(left.public_send(operator, right)) }

      result = schema.call(item: {value: ""})
      expect(result).to be_success
      expect(result.to_h).to eq(item: {value: nil})
    end

    it "accepts a union on one side of #{operator}" do
      left = Dry::Schema.Params { required(:value).value(Types::Params::String | Types::Params::Integer) }
      right = Dry::Schema.Params { required(:value).value(:integer) }
      schema = Dry::Schema.Params { required(:item).schema(left.public_send(operator, right)) }

      result = schema.call(item: {value: "1"})
      expect(result).to be_success
      expect(result.to_h).to eq(item: {value: 1})
      expect(schema.call(item: {value: "one"}).errors.to_h).to eq(item: {value: ["must be an integer"]})
    end
  end

  context "with an array with deeply nested hashes that need coercion" do
    context "with coercion" do
      subject(:schema) do
        Dry::Schema.Params do
          required(:sites).array(:hash) do
            required(:visitor).hash(Test::UserSchema | Test::GuestSchema)
          end
        end
      end

      let(:result) do
        schema.(input)
      end

      context "with unexpected keys" do
        let(:input) do
          {sites: [
            {visitor: {foo: "bar", login: "jane", age: 36}},
            {visitor: {bar: "foo", login: "john", age: 25}}
          ]}
        end

        it "uses a merged key-map to sanitize keys" do
          expect(result[:sites][0][:visitor].keys).to eql(%i[login age])
          expect(result[:sites][1][:visitor].keys).to eql(%i[login age])
        end
      end

      context "with values that need coercion" do
        let(:input) do
          {sites: [
            {visitor: {login: "jane", age: "36"}},
            {visitor: {login: "john", age: "25"}}
          ]}
        end

        it "uses a merged key-map to sanitize keys" do
          expect(result[:sites][0][:visitor]).to eql(login: "jane", age: 36)
          expect(result[:sites][1][:visitor]).to eql(login: "john", age: 25)
        end
      end
    end
  end
end
