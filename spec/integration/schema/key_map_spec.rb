# frozen_string_literal: true

RSpec.describe Dry::Schema, "#key_map" do
  it "coerces and checks keys at each hash depth admitted by an alternative" do
    object = Dry::Schema.Params { required(:item).hash { required(:id).filled(:integer) } }
    list = Dry::Schema.Params { required(:item).array(:hash) { required(:name).filled(:string) } }
    grid = Dry::Schema.Params { required(:item).array { array(:hash) { required(:ref).filled(:integer) } } }

    [object | list | grid, grid | list | object].each do |alternatives|
      schema = Dry::Schema.Params do
        config.validate_keys = true
        required(:data).schema(alternatives)
      end

      [
        [{"id" => "1"}, {id: 1}],
        [[{"name" => "one"}], [{name: "one"}]],
        [[[{"ref" => "2"}]], [[{ref: 2}]]]
      ].each do |input, expected|
        result = schema.call("data" => {"item" => input})
        expect(result).to be_success
        expect(result.to_h).to eq(data: {item: expected})
      end

      misplaced = schema.call("data" => {"item" => [[{"name" => "one", "ref" => "2"}]]})
      expect(misplaced.errors.to_h).to eq(data: {item: {0 => {0 => {name: ["is not allowed"]}}}})

      restored = Dry::Schema::KeyMap.new(schema.key_map.dump)
      expect(restored.dump).to eq(schema.key_map.dump)
      expect(restored.write("data" => {"item" => [[{"ref" => "2", "name" => "one"}]]}))
        .to eq("data" => {"item" => [[{"ref" => "2"}]]})
    end
  end

  it "distinguishes nested variants from a flattening array constructor at another depth" do
    members = Types::Params::Array.of(Types::Params::Hash.schema(id: Types::Params::Integer))
    object = Dry::Schema.Params { required(:item).hash { required(:id).filled } }
    list = Dry::Schema.Params { required(:item).array(:hash) { required(:name).filled } }
    rows = Dry::Schema.Params { required(:rows).array(:hash, object | list) }
    grid = Dry::Schema.Params do
      required(:rows).array { array(:hash) { required(:item).value(members.constructor(&:flatten)) } }
    end
    schema = Dry::Schema.Params do
      config.validate_keys = true
      required(:data).schema(rows | grid)
    end

    result = schema.call(data: {rows: [[{item: [[{id: "1"}]]}]]})
    expect(result).to be_success
    expect(result[:data]).to eq(rows: [[{item: [{id: 1}]}]])
  end

  context "with an inherited schema" do
    it "copies key map from the parent and includes new keys from child" do
      parent = Dry::Schema.define do
        required(:name).filled(:string)
      end

      child = Dry::Schema.define(parent: parent) do
        required(:email).filled(:string)
      end

      expect(child.key_map.map(&:name).sort).to eql(%i[email name])
    end
  end

  context "with an inherited params" do
    it "copies key map from the parent and includes new keys from child" do
      parent = Dry::Schema.Params do
        required(:name).filled(:string)
      end

      child = Dry::Schema.Params(parent: parent) do
        required(:email).filled(:string)
      end

      expect(child.key_map.map(&:name).sort).to eql(%w[email name])
    end
  end
end
