# frozen_string_literal: true

require "dry/schema/messages/yaml"
require "dry/schema/messages/template"

RSpec.describe Dry::Schema::Messages::YAML do
  subject(:messages) do
    Dry::Schema::Messages::YAML.build
  end

  describe "#[]" do
    context "with default config" do
      it "returns text and optional meta" do
        template, meta = messages[:filled?, path: [:name]]

        expect(template.()).to eql("must be filled")
        expect(meta).to eql({})
      end
    end

    context "with custom top-level namespace config" do
      subject(:messages) do
        Dry::Schema::Messages::YAML.build(top_namespace: "my_app")
      end

      it "returns text and optional meta" do
        template, meta = messages[:filled?, path: [:name]]

        expect(template.()).to eql("must be filled")
        expect(meta).to eql({})
      end
    end

    it "expands each configured root and keeps the rule name literal" do
      backend = described_class.build(lookup_paths: ["%<path>s.%<root>s.%<root>s.%<predicate>s"])
      messages = backend.merge("%<locale>s.en.dry_schema.errors.en.dry_schema.errors.filled?" => "required")

      template, = messages[:filled?, path: "%<locale>s"]
      expect(template.()).to eql("required")
    end

    context "with no load paths" do
      subject(:messages) do
        Dry::Schema::Messages::YAML.build(load_paths: [])
      end

      it "does not cause data to be nil, leading to a NoMethodError" do
        result = messages[:filled?, path: [:name]]

        expect(result).to be_nil
      end
    end

    context "interpolation" do
      subject(:messages) do
        Dry::Schema::Messages::YAML.build.merge(
          stringify_keys(
            en: {
              dry_schema: {
                errors: {
                  format?: {
                    text: "%{input} looks weird",
                    code: "bad"
                  }
                }
              }
            }
          )
        )
      end

      it "interpolates into text" do
        template, meta = messages[:format?, path: [:name]]

        expect(template.(input: "it really")).to eql("it really looks weird")
        expect(meta).to eql(code: "bad")
      end
    end
  end

  describe "#rule" do
    it "looks up the literal name and namespace even if they contain the locale token" do
      backend = messages.merge(
        "en.dry_schema.%<locale>s.rules.%<locale>s" => "Literal rule",
        "en.dry_schema.en.rules.en" => "Locale rule"
      )

      expect(backend.namespaced("%<locale>s").rule("%<locale>s")).to eql("Literal rule")
    end
  end

  describe "#get" do
    it "expands locale tokens and escaped percent signs in an explicit lookup key" do
      backend = messages.merge("en.en.tax%" => "Tax")
      key = "%<locale>s.%<locale>s.tax%%"

      expect(backend.key?(key)).to be(true)
      expect(backend.get(key).fetch(:text)).to eql("Tax")
    end
  end

  describe "#merge" do
    context "with :text and meta" do
      it "nests the message hash" do
        merged = messages.merge(
          stringify_keys(
            en: {
              dry_schema: {
                errors: {
                  format?: {
                    text: "%{input} looks weird",
                    code: 102
                  }
                }
              }
            }
          )
        )

        expect(merged.data["en.dry_schema.errors.format?"])
          .to eql(text: "%{input} looks weird", meta: {code: 102})
      end
    end
  end

  describe ".flat_hash" do
    subject(:output) { Dry::Schema::Messages::YAML.flat_hash(input) }

    let(:input) do
      stringify_keys(en: {dry_schema: {errors: messages}})
    end

    describe "simple text messages" do
      let(:messages) do
        {format?: "not ok",
         else?: "should be something else"}
      end

      it "returns string templates" do
        expect(output).to eql(
          "en.dry_schema.errors.else?" => {
            text: "should be something else",
            meta: {}
          },
          "en.dry_schema.errors.format?" => {
            text: "not ok",
            meta: {}
          }
        )
      end
    end

    describe "messages with meta" do
      let(:messages) do
        {
          gt?: {
            text: "must be greater",
            code: 856
          },
          size?: {
            arg: {
              default: "size must be good",
              range: {
                text: "size must fit within the range",
                code: 312
              }
            },
            value: {
              string: {
                arg: {
                  default: "length must be good",
                  range: {
                    text: "length must fit within the range",
                    code: 423
                  }
                }
              }
            }
          },
          rules: {
            format?: {
              text: "not ok",
              code: -101
            },
            text: {
              filled?: {
                text: "text not filled",
                code: 476
              }
            }
          }
        }
      end

      it "returns string templates" do
        expect(output).to eql(
          "en.dry_schema.errors.gt?" => {
            text: "must be greater", meta: {code: 856}
          },
          "en.dry_schema.errors.size?.arg.default" => {
            text: "size must be good", meta: {}
          },
          "en.dry_schema.errors.size?.arg.range" => {
            text: "size must fit within the range", meta: {code: 312}
          },
          "en.dry_schema.errors.size?.value.string.arg.default" => {
            text: "length must be good", meta: {}
          },
          "en.dry_schema.errors.size?.value.string.arg.range" => {
            text: "length must fit within the range", meta: {code: 423}
          },
          "en.dry_schema.errors.rules.format?" => {
            text: "not ok", meta: {code: -101}
          },
          "en.dry_schema.errors.rules.text.filled?" => {
            text: "text not filled", meta: {code: 476}
          }
        )
      end
    end
  end
end
