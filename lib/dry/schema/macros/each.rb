# frozen_string_literal: true

module Dry
  module Schema
    module Macros
      # Macro used to specify predicates for each element of an array
      #
      # @api private
      class Each < DSL
        # @api private
        def value(*args, **opts, &block)
          # Skip iteration for another valid branch of a sum. A declared
          # scalar without a map method needs an array error instead.
          container = schema_dsl.types[name] if schema_dsl
          @array_guard =
            if container.is_a?(::Dry::Types::Sum) && primitive_inferrer[container].include?(::Array)
              :implication
            elsif container.respond_to?(:primitive) && !container.primitive?(EMPTY_ARRAY) &&
                !container.primitive.method_defined?(:map)
              :and
            end

          extract_type_spec(args, set_type: false) do |*predicates, type_spec:, type_rule:|
            if type_spec && !type_spec.is_a?(Dry::Types::Type)
              type(schema_dsl.array[type_spec])
            end

            unless type_spec.equal?(:hash)
              explicit_member = type_spec if type_spec.is_a?(::Dry::Types::Type)
              block = array_member_block(block, explicit_member)
            end

            append_macro(Macros::Value) do |macro|
              macro.call(*predicates, type_spec: type_spec, type_rule: type_rule, **opts, &block)
            end
          end
        end

        # @api private
        def to_ast(*)
          node = [:each, trace.to_ast]
          @array_guard ? [@array_guard, [trace.array?.to_ast, node]] : node
        end
        alias_method :ast, :to_ast
      end
    end
  end
end
