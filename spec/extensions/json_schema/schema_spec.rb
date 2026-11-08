# frozen_string_literal: true

require "json_schemer"

RSpec.describe Dry::Schema::JSON, "#json_schema" do
  before do
    Dry::Schema.load_extensions(:json_schema)
  end

  shared_examples "metaschema validation" do
    describe "validating against the metaschema" do
      it "produces a valid json schema document for draft6" do
        input = schema.respond_to?(:json_schema) ? schema.json_schema : schema

        expect(JSONSchemer.validate_schema(input).to_a).to be_empty
      end
    end
  end

  context "when using a realistic schema with nested data" do
    subject(:schema) do
      Dry::Schema.JSON do
        required(:email).value(:string)

        optional(:age).value(:integer)

        required(:roles).array(:hash) do
          required(:name).value(:string, min_size?: 12, max_size?: 36)

          required(:metadata).hash do
            required(:assigned_at).value(:time)
          end
        end

        optional(:address).hash do
          optional(:street).value(:string)
        end

        required(:id) { str? | int? }
      end
    end

    include_examples "metaschema validation"

    it "returns the correct json schema" do
      expect(schema.json_schema).to eql(
        "$schema": "http://json-schema.org/draft-06/schema#",
        type: "object",
        properties: {
          email: {
            type: "string"
          },
          age: {
            type: "integer"
          },
          roles: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: {
                  type: "string",
                  minLength: 12,
                  maxLength: 36
                },
                metadata: {
                  type: "object",
                  properties: {
                    assigned_at: {
                      format: "time",
                      type: "string"
                    }
                  },
                  required: %w[assigned_at]
                }
              },
              required: %w[name metadata]
            }
          },
          address: {
            type: "object",
            properties: {
              street: {
                type: "string"
              }
            },
            required: []
          },
          id: {
            anyOf: [
              {type: "string"},
              {type: "integer"}
            ]
          }
        },
        required: %w[email roles id]
      )
    end
  end

  context "when using maybe types" do
    include_examples "metaschema validation"

    subject(:schema) do
      Dry::Schema.JSON do
        required(:email).maybe(:string)
      end
    end

    it "returns the correct json schema" do
      expect(schema.json_schema).to eql(
        "$schema": "http://json-schema.org/draft-06/schema#",
        type: "object",
        properties: {
          email: {
            type: %w[null string]
          }
        },
        required: %w[email]
      )
    end
  end

  it "accepts nil for a maybe value with an enum constraint" do
    schema = Dry::Schema.JSON do
      required(:color).maybe(:string, included_in?: %w[red blue])
    end
    validator = JSONSchemer.schema(schema.json_schema)

    expect([nil, "red", "green"].select { |color| validator.valid?({"color" => color}) })
      .to eq([nil, "red"])
  end

  context "when using maybe array types" do
    include_examples "metaschema validation"

    subject(:schema) do
      Dry::Schema.JSON do
        required(:list).maybe(:array).each(:str?)
      end
    end

    it "returns the correct json schema" do
      expect(schema.json_schema).to eql(
        "$schema": "http://json-schema.org/draft-06/schema#",
        type: "object",
        properties: {
          list: {
            type: %w[null array],
            items: {
              type: "string"
            }
          }
        },
        required: %w[list]
      )
    end
  end

  context "when using maybe array types with nested properties" do
    include_examples "metaschema validation"

    subject(:schema) do
      Dry::Schema.JSON do
        required(:list).maybe(:array).each do
          hash do
            required(:name).value(:string)
          end
        end
      end
    end

    it "returns the correct json schema" do
      expect(schema.json_schema).to eql(
        "$schema": "http://json-schema.org/draft-06/schema#",
        type: "object",
        properties: {
          list: {
            type: %w[null array],
            items: {
              type: "object",
              properties: {
                name: {
                  type: "string"
                }
              },
              required: %w[name]
            }
          }
        },
        required: %w[list]
      )
    end
  end

  describe "combined predicates" do
    it "requires each disjunction joined by AND to pass" do
      schema = Dry::Schema.JSON do
        required(:n) { (eql?(1) | eql?(2)) & (eql?(2) | eql?(3)) }
      end
      validator = JSONSchemer.schema(schema.json_schema)

      expect([1, 2, 3].select { |n| validator.valid?({"n" => n}) }).to eq([2])
    end

    it "uses the property's type for predicates inside OR" do
      schema = Dry::Schema.JSON do
        required(:name) { (filled? | eql?("anonymous")) & (str? & max_size?(20)) }
        required(:tags) { array? & (max_size?(1) | min_size?(3)) }
      end
      validator = JSONSchemer.schema(schema.json_schema)

      expect(validator.valid?({"name" => "Jane", "tags" => []})).to be(true)
      expect(validator.valid?({"name" => "", "tags" => []})).to be(false)
      expect(validator.valid?({"name" => "Jane", "tags" => [1, 2]})).to be(false)
    end

    it "keeps both constraints when predicates produce the same keyword" do
      schema = Dry::Schema.JSON do
        required(:name) { (min_size?(3) & filled?) & str? }
        required(:number) { (int? & filled?) & odd? }
      end
      validator = JSONSchemer.schema(schema.json_schema)

      expect(validator.valid?({"name" => "abc", "number" => 3})).to be(true)
      expect(validator.valid?({"name" => "a", "number" => 3})).to be(false)
      expect(validator.valid?({"name" => "abc", "number" => 2})).to be(false)
    end

    it "applies the consequence of an implication only when its condition holds" do
      schema = Dry::Schema.JSON do
        required(:value) { array? > size?(2) }
      end
      validator = JSONSchemer.schema(schema.json_schema)

      expect(["a", [], [1], [1, 2], [1, 2, 3]].select { |value|
        validator.valid?({"value" => value})
      }).to eq(["a", [1, 2]])
    end

    it "applies an array constant to the array itself" do
      schema = Dry::Schema.JSON do
        required(:list) { eql?([]) & array? }
      end
      validator = JSONSchemer.schema(schema.json_schema)

      expect(validator.valid?({"list" => []})).to be(true)
      expect(validator.valid?({"list" => [[]]})).to be(false)
    end

    it "applies each member constraint at the corresponding array depth" do
      schema = Dry::Schema.JSON do
        required(:rows).array { array(:integer) { gt?(0) | lt?(0) } }
      end
      validator = JSONSchemer.schema(schema.json_schema)

      expect(validator.valid?({"rows" => [[-1, 1]]})).to be(true)
      expect(validator.valid?({"rows" => [[0]]})).to be(false)
      expect(validator.valid?({"rows" => [1]})).to be(false)
      expect(validator.valid?({"rows" => [["text"]]})).to be(false)
    end
  end

  context "when using array types with combined schemas" do
    include_examples "metaschema validation"

    subject(:schema) do
      schema_1 = Dry::Schema.JSON do
        required(:name).value(:string)
      end

      schema_2 = Dry::Schema.JSON do
        optional(:age).value(:string)
      end

      Dry::Schema.JSON do
        required(:list).value(:array).each { schema_1 | schema_2 }
      end
    end

    it "returns the correct json schema" do
      expect(schema.json_schema).to eql(
        "$schema": "http://json-schema.org/draft-06/schema#",
        type: "object",
        properties: {
          list: {
            type: "array",
            items: {
              anyOf: [
                {
                  type: "object",
                  properties: {
                    name: {
                      type: "string"
                    }
                  },
                  required: %w[name]
                },
                {
                  type: "object",
                  properties: {
                    age: {
                      type: "string"
                    }
                  },
                  required: []
                }
              ]
            }
          }
        },
        required: %w[list]
      )
    end
  end

  context "when using value which is an OR of different types of arrays" do
    include_examples "metaschema validation"

    subject(:schema) do
      string_array = Types::Array.of(Types::String)
      integer_array = Types::Array.of(Types::Integer)

      Dry::Schema.JSON do
        required(:list).value(string_array | integer_array)
      end
    end

    it "returns the correct json schema" do
      expect(schema.json_schema).to eql(
        "$schema": "http://json-schema.org/draft-06/schema#",
        type: "object",
        properties: {
          list: {
            anyOf: [
              {
                type: "array",
                items: {
                  type: "string"
                }
              },
              {
                type: "array",
                items: {
                  type: "integer"
                }
              }
            ]
          }
        },
        required: %w[list]
      )
    end
  end

  describe "filled macro" do
    context "when there is no type" do
      include_examples "metaschema validation"

      subject(:schema) do
        Dry::Schema.JSON do
          required(:email).filled
        end
      end

      it "returns the correct json schema" do
        expect(schema.json_schema).to include(
          properties: {
            email: {
              not: {enum: [nil, "", [], {}]}
            }
          }
        )
      end
    end

    context "when its a string type" do
      include_examples "metaschema validation"

      subject(:schema) do
        Dry::Schema.JSON do
          required(:email).filled(:str?)
        end
      end

      it "returns the correct json schema" do
        expect(schema.json_schema).to include(
          properties: {
            email: {
              type: "string",
              minLength: 1
            }
          }
        )
      end
    end

    context "when its an array type" do
      subject(:schema) do
        Dry::Schema.JSON do
          required(:tags).filled(:array)
        end
      end

      it "requires at least one item" do
        expect(schema.json_schema[:properties][:tags]).to eq(type: "array", minItems: 1)
      end
    end
  end

  context "when using non-convertible types" do
    unsupported_cases = [
      Types.Constructor(Struct.new(:name)),
      {excluded_from?: ["foo"]},
      {format?: /something/},
      {bytesize?: 2}
    ]

    unsupported_cases.each do |predicate|
      subject(:schema) do
        Dry::Schema.JSON do
          required(:nested).hash do
            if predicate.is_a?(Hash)
              required(:key).filled(**predicate)
            else
              required(:key).filled(predicate)
            end
          end
        end
      end

      it "raises an unknown type conversion error by default" do
        expect { schema.json_schema }.to raise_error(
          Dry::Schema::JSONSchema::SchemaCompiler::UnknownConversionError, /predicate/
        )
      end

      it "allows for the schema to be generated loosely" do
        expect { schema.json_schema(loose: true) }.not_to raise_error
      end
    end
  end

  it "omits negated unsupported predicates in loose mode" do
    schema = Dry::Schema.JSON do
      required(:value) { !excluded_from?(["x"]) }
      required(:conditional) { (str? & excluded_from?(["x"])) > eql?("a") }
    end

    expect { schema.json_schema }.to raise_error(
      Dry::Schema::JSONSchema::SchemaCompiler::UnknownConversionError
    )
    expect(schema.json_schema(loose: true)[:properties]).to eq(value: {}, conditional: {})
  end

  it "does not turn a negated Ruby integer storage size into an impossible JSON constraint" do
    schema = Dry::Schema.JSON do
      required(:id) { int? & !size?(2) }
    end

    expect { schema.json_schema }.to raise_error(
      Dry::Schema::JSONSchema::SchemaCompiler::UnknownConversionError, /size\?/
    )
    expect(schema.json_schema(loose: true)[:properties][:id]).to eq(type: "integer")
  end

  context "when using enums" do
    include_examples "metaschema validation"

    subject(:schema) do
      Dry::Schema.JSON do
        required(:color).value(:str?, included_in?: %w[red blue])
        required(:shade).maybe(array[Types::String.enum("light", "medium", "dark")])
      end
    end

    it "returns the correct json schema" do
      expect(schema.json_schema).to eql(
        "$schema": "http://json-schema.org/draft-06/schema#",
        type: "object",
        properties: {
          color: {
            type: "string",
            enum: %w[red blue]
          },
          shade: {
            type: %w[null array],
            items: {
              type: "string",
              enum: %w[light medium dark]
            }
          }
        },
        required: %w[color shade]
      )
    end
  end

  context "when using const" do
    include_examples "metaschema validation"

    subject(:schema) do
      Dry::Schema.JSON do
        required(:version).value(:integer, eql?: 1)
      end
    end

    it "returns the correct json schema" do
      expect(schema.json_schema).to eql(
        "$schema": "http://json-schema.org/draft-06/schema#",
        type: "object",
        properties: {
          version: {
            type: "integer",
            const: 1
          }
        },
        required: %w[version]
      )
    end
  end

  describe "inferring types" do
    {
      array: {type: "array"},
      bool: {type: "boolean"},
      date: {type: "string", format: "date"},
      date_time: {type: "string", format: "date-time"},
      decimal: {type: "number"},
      float: {type: "number"},
      hash: {type: "object"},
      integer: {type: "integer"},
      nil: {type: "null"},
      string: {type: "string"},
      time: {type: "string", format: "time"},
      uuid_v1?: {pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-1[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"},
      uuid_v2?: {pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-2[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"},
      uuid_v3?: {pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-3[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"},
      uuid_v4?: {pattern: "^[a-f0-9]{8}-?[a-f0-9]{4}-?4[a-f0-9]{3}-?[89ab][a-f0-9]{3}-?[a-f0-9]{12}$"},
      uuid_v5?: {pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-5[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"},
      uuid_v6?: {pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-6[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"},
      uuid_v7?: {pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-7[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"},
      uuid_v8?: {pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-8[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"}
    }.each do |type_spec, type_opts|
      describe "type: #{type_spec.inspect}" do
        subject(:schema) do
          Dry::Schema.define { required(:key).value(type_spec) }.json_schema
        end

        include_examples "metaschema validation"

        it "infers with correct default options - #{type_opts.to_json}" do
          expect(schema).to include(
            type: "object",
            properties: {key: type_opts},
            required: ["key"]
          )
        end
      end
    end
  end

  describe "special string predictes" do
    {
      {uri?: "https"} => {type: "string", format: "uri"},
      {size?: 5} => {type: "string", minLength: 5, maxLength: 5},
      {format?: /\A\d{3}-\d{4}\z/} => {type: "string", pattern: "\\A\\d{3}-\\d{4}\\z"}
    }.each do |type_spec, type_opts|
      describe "type: #{type_spec.inspect}" do
        subject(:schema) do
          Dry::Schema.define { required(:key).value(:string, **type_spec) }.json_schema
        end

        include_examples "metaschema validation"

        it "infers with correct default options - #{type_opts.to_json}" do
          expect(schema).to include(
            properties: {key: type_opts}
          )
        end
      end
    end
  end

  describe "special number predictes" do
    {
      {gt?: 5} => {type: "integer", exclusiveMinimum: 5},
      {gteq?: 5} => {type: "integer", minimum: 5},
      {lt?: 5} => {type: "integer", exclusiveMaximum: 5},
      {lteq?: 5} => {type: "integer", maximum: 5},
      odd?: {type: "integer", not: {multipleOf: 2}},
      even?: {type: "integer", multipleOf: 2}
    }.each do |type_spec, type_opts|
      describe "type: #{type_spec.inspect}" do
        subject(:schema) do
          if type_spec.is_a?(Hash)
            Dry::Schema.define { required(:key).value(:int?, **type_spec) }.json_schema
          else
            Dry::Schema.define { required(:key).value(type_spec) }.json_schema
          end
        end

        include_examples "metaschema validation"

        it "infers with correct default options - #{type_opts.to_json}" do
          expect(schema).to include(
            properties: {key: type_opts}
          )
        end
      end
    end
  end

  describe "special boolean predicates" do
    it "negates each boolean constant" do
      schema = Dry::Schema.JSON do
        required(:off) { !true? }
        required(:on) { !false? }
      end
      validator = JSONSchemer.schema(schema.json_schema)

      expect(validator.valid?({"off" => false, "on" => true})).to be(true)
      expect(validator.valid?({"off" => true, "on" => false})).to be(false)
    end

    {
      true?: {const: true},
      false?: {const: false}
    }.each do |type_spec, type_opts|
      describe "type: #{type_spec.inspect}" do
        subject(:schema) do
          Dry::Schema.define { required(:key).value(type_spec) }.json_schema
        end

        include_examples "metaschema validation"

        it "infers with correct default options - #{type_opts.to_json}" do
          expect(schema).to include(
            properties: {key: type_opts}
          )
        end
      end
    end
  end
end
