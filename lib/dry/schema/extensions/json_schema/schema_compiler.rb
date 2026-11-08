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
        TO_INTEGER = ->(v) { v.to_i }.freeze

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
          min_size?: {minLength: TO_INTEGER},
          max_size?: {maxLength: TO_INTEGER},
          size?: {maxLength: TO_INTEGER, minLength: TO_INTEGER},
          format?: {
            pattern: proc do |x|
              x.to_s.delete_prefix("(?-mix:").delete_suffix(")")
            end
          },
          true?: {},
          false?: {},
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

        ARRAY_PREDICATES = PREDICATE_TO_TYPE.merge(
          min_size?: {minItems: TO_INTEGER},
          max_size?: {maxItems: TO_INTEGER}
        ).freeze

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
          alternatives = node.map do |child|
            branch = {}
            visit(child, branch, options)
            branch
          end

          if target.key?(:anyOf)
            (target[:allOf] ||= []) << {anyOf: alternatives}
          else
            target[:anyOf] = alternatives
          end
        end

        def visit_implication(node, target, options)
          options = options.merge(required: false)
          node.each { |child| visit(child, target, options) }
        end

        def visit_each(node, target, options)
          items = (target[:items] ||= {})
          visit(node, items, options.except(:type))
        end

        def visit_key(node, target, options)
          name, rule = node
          target.fetch(:required) << name.to_s if options.fetch(:required, true)
          visit(rule, target.fetch(:properties).fetch(name))
        end

        def visit_not(node, target, options)
          _kind, predicate = node
          visit_predicate(predicate, target, options)
        end

        def visit_predicate(node, target, options)
          name, args = node
          if name == :key?
            target.fetch(:properties)[args.first.last] = {}
          else
            type = target[:type] || options[:type]
            merge_opts!(target, predicate_options(name, args, type))
          end
        end

        def predicate_options(name, args, type)
          return fetch_filled_options(type) if name == :filled?

          predicates = type&.include?("array") ? ARRAY_PREDICATES : PREDICATE_TO_TYPE
          options = predicates.fetch(name) do
            raise_unknown_conversion_error!(:predicate, name) unless loose?
            EMPTY_HASH
          end
          options.transform_values { |v| v.respond_to?(:call) ? v.call(args.first.last) : v }
        end

        def fetch_filled_options(type)
          return {minLength: 1} if type == "string"

          raise_unknown_conversion_error!(:type, :array) if type == "array" && !loose?
          {not: {type: "null"}}
        end

        # @api private
        def merge_opts!(orig_opts, new_opts)
          new_type = new_opts[:type]
          orig_type = orig_opts[:type]

          if orig_type && new_type && orig_type != new_type
            new_opts[:type] = [orig_type, new_type].flatten.uniq
          end

          orig_opts.merge!(new_opts)
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
