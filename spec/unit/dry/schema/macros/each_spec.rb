# frozen_string_literal: true

require "dry/schema/macros/each"

RSpec.describe Dry::Schema::Macros::Each do
  subject(:macro) do
    Dry::Schema::Macros::Each.new(:name)
  end

  describe "#to_rule" do
    it "evaluates a predicate block without a schema DSL" do
      rule = macro.value { str? }.to_rule

      expect(rule.(%w[foo])).to be_success
      expect(rule.([1])).to be_failure
    end

    it "builds a valid rule with additional predicates" do
      macro.value(:str?, size?: 2..20)

      rule = macro.to_rule

      expect(rule.(%w[foo foobar])).to be_success
      expect(rule.(%w[f foo])).to be_failure
      expect(rule.(["f", "foo" * 20])).to be_failure
    end
  end
end
