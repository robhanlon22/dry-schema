# frozen_string_literal: true

require "dry/schema/types_merger/schema_alternatives"

module Dry
  module Schema
    module Macros
      # Macro used to specify a nested schema
      #
      # @api private
      class Schema < Value
        # @api private
        def call(*args, &block)
          super(*args, &nil) unless args.empty?

          if args.size.equal?(1) && (op = args.first).is_a?(::Dry::Logic::Operations::Abstract)
            process_operation(op)
          end

          if block
            schema = define(*args, &block)
            import_steps(schema)
            trace << schema.to_rule
          end

          self
        end

        private

        # @api private
        def process_operation(op)
          type(operation_type(op))
        end

        def operation_type(operation)
          return hash_type.schema(operation.types) if operation.is_a?(Processor)
          return hash_type.schema(EMPTY_HASH) unless operation.is_a?(::Dry::Logic::Operations::Abstract)

          operands = operation.rules.map { |branch| operation_type(branch) }
          if operation.is_a?(::Dry::Logic::Operations::Or)
            left, right = operands
            rules = operation.rules.map { |branch| compiler.visit(branch.to_ast) }
            TypesMerger::SchemaAlternatives.new(
              left, right, rules: rules, key_type: TypesMerger::SchemaAlternatives.key_type(left, right)
            )
          else
            operands.reduce { |left, right| merge_operand_types(operation.class, left, right) } ||
              hash_type.schema(EMPTY_HASH)
          end
        end

        def merge_operand_types(operator, left, right)
          if TypesMerger::SchemaIntersection.needed?(left, right)
            TypesMerger::ValueMerger.new(operator).call(left, right)
          else
            lhs = left.name_key_map.transform_values(&:type)
            rhs = right.name_key_map.transform_values(&:type)
            hash_type.schema(schema_dsl.merge_types(operator, lhs, rhs))
          end
        end

        # @api private
        def hash_type
          schema_dsl.resolve_type(:hash)
        end

        # @api private
        # rubocop: disable Metrics/AbcSize
        def define(*args, &)
          definition = schema_dsl.new(path: schema_dsl.path, &)
          schema = definition.call
          type_schema =
            if array_type?(parent_type)
              build_array_type(parent_type, schema.strict_type_schema)
            elsif redefined_schema?(args)
              parent_type.schema(definition.types)
            else
              schema.strict_type_schema
            end
          final_type = optional? ? type_schema.optional : type_schema

          type(final_type)

          if schema.filter_rules?
            schema_dsl[name].filter { hash?.then(schema(schema.filter_schema)) }
          end

          schema
        end
        # rubocop: enable Metrics/AbcSize

        # @api private
        def parent_type
          schema_dsl.types[name]
        end

        # @api private
        def optional?
          parent_type.optional?
        end

        # @api private
        def schema?
          parent_type.respond_to?(:schema)
        end

        # @api private
        def redefined_schema?(args)
          schema? && args.first.is_a?(Processor)
        end
      end
    end
  end
end
