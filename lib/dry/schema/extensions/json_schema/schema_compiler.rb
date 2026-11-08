# frozen_string_literal: true

require "dry/schema/constants"

module Dry
  module Schema
    # @api private
    module JSONSchema
      # @api private
      class SchemaCompiler
        # An error raised when a predicate cannot be converted
        UnknownConversionError = ::Class.new(::StandardError)

        IDENTITY = ->(v) { v }.freeze

        PREDICATE_TO_TYPE = {
          array?: {type: "array"},
          bool?: {type: "boolean"},
          date?: {type: "string", format: "date"},
          date_time?: {type: "string", format: "date-time"},
          decimal?: {type: "number"},
          float?: {type: "number"},
          hash?: {type: "object"},
          int?: {type: "integer"},
          nil?: {type: "null"},
          str?: {type: "string"},
          time?: {type: "string", format: "time"},
          format?: {
            pattern: proc do |x|
              x.to_s.delete_prefix("(?-mix:").delete_suffix(")")
            end
          },
          true?: {const: true},
          false?: {const: false},
          included_in?: {enum: ->(v) { v.to_a }},
          eql?: {const: IDENTITY},
          uri?: {format: "uri"},
          uuid_v1?: {
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-1[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"
          },
          uuid_v2?: {
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-2[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"
          },
          uuid_v3?: {
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-3[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"
          },
          uuid_v4?: {
            pattern: "^[a-f0-9]{8}-?[a-f0-9]{4}-?4[a-f0-9]{3}-?[89ab][a-f0-9]{3}-?[a-f0-9]{12}$"
          },
          uuid_v5?: {
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-5[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"
          },
          uuid_v6?: {
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-6[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"
          },
          uuid_v7?: {
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-7[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"
          },
          uuid_v8?: {
            pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-8[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$"
          },
          gt?: {exclusiveMinimum: IDENTITY},
          gteq?: {minimum: IDENTITY},
          lt?: {exclusiveMaximum: IDENTITY},
          lteq?: {maximum: IDENTITY},
          odd?: {type: "integer", not: {multipleOf: 2}},
          even?: {type: "integer", multipleOf: 2}
        }.freeze

        SIZE_KEYWORDS = {
          "string" => [:minLength, :maxLength],
          "array" => [:minItems, :maxItems],
          "object" => [:minProperties, :maxProperties]
        }.freeze

        # @api private
        def initialize(loose: false)
          @loose = loose
        end

        # @api private
        def call(ast)
          schema = {"$schema": "http://json-schema.org/draft-06/schema#"}
          visit(ast, schema)
          schema
        end

        private

        def visit(node, target, options = EMPTY_HASH)
          kind, body = node
          send(:"visit_#{kind}", body, target, options)
        end

        def visit_set(node, target, options)
          object = {type: "object", properties: {}, required: Set.new}
          options = options.except(:type)
          node.each { |child| visit(child, object, options) }
          object[:required] = object[:required].to_a
          merge_opts!(target, object)
        end

        def visit_and(node, target, options)
          # A type predicate anywhere in this conjunction applies to every operand.
          remaining = []
          each_conjunct(node) do |child|
            if child.first == :predicate && PREDICATE_TO_TYPE[child.last.first]&.key?(:type)
              visit(child, target, options)
            else
              remaining << child
            end
          end
          if remaining.size > 1 && remaining.any? { |kind,| kind == :set }
            options = options.merge(expression: true)
          end
          remaining.each { |child| visit(child, target, options) }
        end

        def each_conjunct(node, &block)
          node.each do |child|
            if child.first == :and
              each_conjunct(child.last, &block)
            else
              yield child
            end
          end
        end

        def visit_or(node, target, options)
          options = options.merge(type: target[:type] || options[:type])
          alternatives = node.map { |child| subschema(child, options) }
          merge_opts!(target, {anyOf: alternatives})
        end

        def visit_implication(node, target, options)
          condition, rule = node

          if condition.first == :predicate && condition.last.first == :key?
            visit(condition, target, options)
            visit(rule, target, options.merge(required: false))
          elsif condition.first == :predicate && condition.last.first == :array? && rule.first == :each
            # JSON Schema applies items only to arrays.
            visit(rule, target, options)
          elsif condition.first == :not && condition.last.dig(1, 0) == :nil?
            # The maybe macro emits !nil? > rule.
            merge_opts!(target, nullable(subschema(rule, options)))
          else
            options = options.merge(type: target[:type] || options[:type])
            inverse = negated(condition, options)
            return if inverse.empty?

            type = inverse[:not][:type]
            options = options.merge(type: type) if type
            merge_opts!(target, {anyOf: [inverse, subschema(rule, options)]})
          end
        end

        def nullable(schema)
          # These keywords can reject null even when the type includes it.
          if schema[:type] && %i[const enum not anyOf allOf].none? { |key| schema.key?(key) }
            schema.merge(type: ["null", *schema[:type]].uniq)
          else
            {anyOf: [{type: "null"}, schema]}
          end
        end

        def subschema(node, options)
          schema = {}
          visit(node, schema, options.merge(expression: true))
          schema
        end

        def visit_each(node, target, options)
          items = (target[:items] ||= {})
          visit(node, items, options.except(:type).merge(expression: true))
        end

        def visit_key(node, target, options)
          name, rule = node
          target.fetch(:required) << name.to_s if options.fetch(:required, true)
          property = target.fetch(:properties).fetch(name)
          standalone = standalone_property(rule) unless options[:expression]
          standalone ? merge_opts!(property, standalone) : visit(rule, property, options.except(:required, :type))
        end

        # Standalone properties have historically exported a few predicates
        # approximately. Boolean expressions need their actual truth conditions.
        def standalone_property(rule)
          kind, body = rule
          if kind == :predicate
            return EMPTY_HASH if body.first == :true? || body.first == :false?
            return {not: {type: "null"}} if body.first == :filled?
          elsif kind == :and && !loose? && body.all? { |child| child.first == :predicate }
            left, right = body.map { |child| child.last.first }
            if (left == :array? && right == :filled?) || (left == :filled? && right == :array?)
              raise_unknown_conversion_error!(:type, :array)
            end
          end
          nil
        end

        def visit_not(node, target, options)
          options = options.merge(type: target[:type] || options[:type])
          merge_opts!(target, negated(node, options))
        end

        def negated(node, options)
          # Dropping an unknown condition inside NOT would make it more restrictive.
          {not: subschema(node, options.merge(strict: true))}
        rescue UnknownConversionError
          raise if !loose? || options[:strict]

          EMPTY_HASH
        end

        def visit_predicate(node, target, options)
          name, args = node
          if name == :key?
            target.fetch(:properties)[args.first.last] = {}
          else
            type = target[:type] || options[:type]
            merge_opts!(target, predicate_options(name, args, type, options[:strict]))
          end
        end

        def predicate_options(name, args, type, strict)
          return fetch_filled_options(type) if name == :filled?

          if %i[min_size? max_size? size?].include?(name)
            # Ruby measures integer storage in bytes. JSON has no such constraint to negate.
            if strict && Array(type).include?("integer")
              raise_unknown_conversion_error!(:predicate, name)
            end
            return size_options(name, args.first.last.to_i, type)
          end

          options = PREDICATE_TO_TYPE.fetch(name) do
            raise_unknown_conversion_error!(:predicate, name) if strict || !loose?
            EMPTY_HASH
          end
          options.transform_values { |v| v.respond_to?(:call) ? v.call(args.first.last) : v }
        end

        def size_options(name, value, type)
          dimensions = type ? Array(type).filter_map { |t| SIZE_KEYWORDS[t] } : SIZE_KEYWORDS.values
          dimensions.each_with_object({}) do |(min, max), sizes|
            sizes[min] = value unless name == :max_size?
            sizes[max] = value unless name == :min_size?
          end
        end

        def fetch_filled_options(type)
          return {minLength: 1} if type == "string"
          return {minItems: 1} if type == "array"
          return {minProperties: 1} if type == "object"
          return {not: {enum: [nil, "", [], {}]}} if !type || type.is_a?(::Array)

          {not: {type: "null"}}
        end

        # @api private
        def merge_opts!(target, constraints)
          constraints.each do |keyword, value|
            if !target.key?(keyword)
              target[keyword] = value
            elsif target[keyword] != value
              # Both constraints must hold, even when they use the same keyword.
              (target[:allOf] ||= []) << {keyword => value}
            end
          end
        end

        # @api private
        def loose?
          @loose
        end

        def raise_unknown_conversion_error!(type, name)
          message = <<~MSG
            Could not find an equivalent conversion for #{type} #{name.inspect}.

            This means that your generated JSON schema may be missing this validation.

            You can ignore this by generating the schema in "loose" mode, i.e.:
                my_schema.json_schema(loose: true)
          MSG

          raise UnknownConversionError, message.chomp
        end
      end
    end
  end
end
