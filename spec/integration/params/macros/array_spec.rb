# frozen_string_literal: true

RSpec.describe "Params / Macros / array" do
  context "array of hashes" do
    subject(:schema) do
      Dry::Schema.Params do
        required(:songs).array(:hash) do
          required(:title).filled(:string)
        end
      end
    end

    it "coerces an empty string to an array" do
      result = schema.("songs" => "")

      expect(result).to be_success
      expect(result.to_h).to eq(songs: [])
    end
  end

  it "coerces nested member declarations at the correct array depth" do
    schema = Dry::Schema.Params do
      required(:rows).array do
        filled(:array).each { maybe(:integer) }
      end
    end

    result = schema.call("rows" => [["1", ""], ["2"]])

    expect(result).to be_success
    expect(result.to_h).to eq(rows: [[1, nil], [2]])
    expect(schema.call(rows: [["bad"]]).errors.to_h).to eq(rows: {0 => {0 => ["must be an integer"]}})
  end

  it "preserves a nullable array's metadata and coercion when typing its members" do
    numbers = Types::Params::Array.meta(label: "numbers")
    schema = Dry::Schema.Params do
      required(:rows).maybe(numbers) { each { filled(:integer) } }
    end

    expect(schema.types[:rows].meta).to include(label: "numbers")
    expect(schema.(rows: "").to_h).to eq(rows: nil)
    expect(schema.(rows: ["2"]).to_h).to eq(rows: [2])
  end

  it "infers an array from each when only its member has a declared type" do
    schema = Dry::Schema.Params do
      required(:rows).value(:array?).each { filled(:integer) }
    end

    result = schema.(rows: ["2"])

    expect(result).to be_success
    expect(result.to_h).to eq(rows: [2])
  end

  it "coerces string keys at the declared array depth" do
    item = Dry::Schema.Params { required(:id).filled(:integer) }
    schema = Dry::Schema.Params do
      config.validate_keys = true
      required(:rows).array { array(:hash, item) }
    end

    result = schema.("rows" => [[{"id" => "2"}]])
    expect(result).to be_success
    expect(result.to_h).to eq(rows: [[{id: 2}]])

    result = schema.("rows" => [[], [{"id" => "bad"}]])
    expect(result.to_h).to eq(rows: [[], [{id: "bad"}]])
    expect(result.errors.to_h).to eq(rows: {1 => {0 => {id: ["must be an integer"]}}})
  end

  it "coerces each alternative in a member block independently" do
    schema = Dry::Schema.Params do
      config.validate_keys = true
      required(:rows).array do
        array(:integer) | hash { required(:id).filled(:integer) }
      end
    end

    result = schema.call("rows" => [["2"], {"id" => "3"}])

    expect(result).to be_success
    expect(result.to_h).to eq(rows: [[2], {id: 3}])
  end

  it "keeps nested keys when a predicate allows nil members" do
    schema = Dry::Schema.Params do
      required(:rows).array { nil? | hash { required(:id).filled(:integer) } }
    end

    result = schema.call(rows: [nil, {"id" => "3"}])

    expect(result).to be_success
    expect(result.to_h).to eq(rows: [nil, {id: 3}])
  end

  it "retains both sides of a member conjunction inside an alternative" do
    %i[Params JSON].each do |processor|
      schema = Dry::Schema.public_send(processor) do
        required(:rows).array do
          (hash { required(:a).filled(:integer) } & hash { required(:b).filled(:string) }) |
            hash { required(:c).filled(:integer) }
        end
      end

      result = schema.call("rows" => [{"c" => 2}, {"a" => 3, "b" => "ok"}])

      expect(result).to be_success
      expect(result.to_h).to eq(rows: [{c: 2}, {a: 3, b: "ok"}])
    end
  end

  it "coerces hash members using the alternative whose predicates match" do
    left = Dry::Schema.Params do
      required(:kind).value(eql?: "left")
      optional(:value).filled(:integer)
      optional(:note).filled(:string)
    end
    right = Dry::Schema.Params do
      required(:kind).value(eql?: "right")
      optional(:value).filled(:string)
      optional(:qty).filled(:integer)
    end

    [left, right].permutation do |first, second|
      schema = Dry::Schema.Params do
        required(:rows).array { hash(first) | hash(second) }
        optional(:groups).array { array(:hash, first) | array(:hash, second) }
      end
      rows = [{"kind" => "left", "value" => "2", "note" => "memo"},
              {"kind" => "right", "value" => "2", "qty" => "3"}]
      expected = [{kind: "left", value: 2, note: "memo"}, {kind: "right", value: "2", qty: 3}]

      result = schema.call("rows" => rows, "groups" => rows.map { |row| [row] })
      expect(result).to be_success
      expect(result.to_h).to eq(rows: expected, groups: expected.map { |row| [row] })

      invalid = {kind: "right", qty: "bad"}
      expect(schema.call(rows: [invalid], groups: [[invalid]]).errors.to_h.keys).to contain_exactly(:rows, :groups)
    end
  end

  it "checks each member predicate against the value coerced by its own branch" do
    upcase = Types::String.constructor(&:upcase)
    downcase = Types::String.constructor(&:downcase)
    upper = Dry::Schema.Params { required(:name).value(upcase, eql?: "abc") }
    lower = Dry::Schema.Params { required(:name).value(downcase, eql?: "ABC") }

    [upper, lower].permutation do |first, second|
      schema = Dry::Schema.Params do
        required(:rows).array { (hash(first) | hash(second)) & hash { required(:count).filled(:integer) } }
      end

      result = schema.call(rows: [{name: "Abc", count: "2"}])
      expect(result[:rows].first[:count]).to eq(2)
      expect(result).to be_failure
      expect(result.errors.to_h.dig(:rows, 0, :name)).not_to be_empty
    end
  end

  it "retains compatible fields from each successful hash alternative" do
    left, right = %i[x y].map do |key|
      Dry::Schema.Params do
        required(:id).filled(:integer)
        optional(key).filled(:integer)
      end
    end

    [left, right].permutation do |first, second|
      schema = Dry::Schema.Params { required(:rows).value(:array).each { hash(first) | hash(second) } }
      result = schema.call("rows" => [{"id" => "1", "x" => "2", "y" => "3"}])

      expect(result).to be_success
      expect(result.to_h).to eq(rows: [{id: 1, x: 2, y: 3}])
    end
  end

  it "retains an explicit member constructor when the block allows alternatives" do
    lowercase = Types::String.constructor(&:downcase)
    schema = Dry::Schema.Params do
      required(:values).array(lowercase) { value(:string) | value(:integer) }
    end

    result = schema.call(values: %w[ABC 23])

    expect(result).to be_success
    expect(result.to_h).to eq(values: %w[abc 23])
  end

  it "reports a shape error when a scalar member is passed to a nested schema or each" do
    item = Dry::Schema.Params { required(:id).filled(:integer) }
    schema = Dry::Schema.Params do
      required(:maps).array(:integer) { value(item) }
      required(:lists).array(:integer) { each { filled(:integer) } }
    end

    result = schema.call(maps: ["1"], lists: ["2"])

    expect(result.to_h).to eq(maps: [1], lists: [2])
    expect(result.errors.to_h).to eq(maps: {0 => ["must be a hash"]}, lists: {0 => ["must be an array"]})
  end

  it "applies each only to the array alternative of a sum" do
    type = Types::Params::Nil | Types::Params::Array
    schema = Dry::Schema.Params { required(:rows).value(type).each { filled(:integer) } }

    expect(schema.call(rows: "").to_h).to eq(rows: nil)
    expect(schema.call(rows: nil)).to be_success
    expect(schema.call(rows: ["2"]).to_h).to eq(rows: [2])
    expect(schema.call(rows: "invalid")).to be_failure
  end

  context "when inherited" do
    subject(:schema) do
      Dry::Schema.Params(parent: parent) do
        optional(:user).array(:hash)
      end
    end

    let(:parent) do
      Dry::Schema.Params do
        optional(:id).value(:integer)
      end
    end

    it "applies coercion and rules" do
      result = schema.("id" => "1", "user" => nil)

      expect(result.errors.to_h).to eql(user: ["must be an array"])
      expect(result.to_h).to eql(id: 1, user: nil)
    end

    context "from multiple parents" do
      subject(:schema) do
        Dry::Schema.Params(parent: [parent, parent2]) do
          optional(:user).array(:hash)
        end
      end

      let(:parent2) do
        Dry::Schema.Params do
          optional(:age).value(:integer, gt?: 17)
        end
      end

      it "applies coercion and rules from both parents" do
        result = schema.("id" => "1", "age" => "12", "user" => nil)

        expect(result.errors.to_h).to eql(user: ["must be an array"],
          age: ["must be greater than 17"])
        expect(result.to_h).to eql(id: 1, user: nil, age: 12)
      end
    end
  end

  context "with a sum type as member" do
    it "applies coercion and rules" do
      schema = Dry::Schema.Params {
        required(:nums).array(Types::Params::Integer | Types::Params::Nil)
      }

      result = schema.(nums: ["3", nil, "1"])

      expect(result).to be_success

      result = schema.(nums: ["3", {}, "1"])

      expect(result).to be_failure
      expect(result.errors.to_h).to eql(nums: {1 => ["must be an integer or cannot be defined"]})
    end
  end
end
