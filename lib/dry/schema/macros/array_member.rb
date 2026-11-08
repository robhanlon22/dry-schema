# frozen_string_literal: true

module Dry
  module Schema
    module Macros
      # Evaluate sibling declarations independently so a type assigned on one
      # side of a disjunction cannot change how the other side is built.
      # @api private
      class ArrayMember < Value
        option :member_type

        def schema_dsl
          @scope ||= @schema_dsl.new(
            path: @schema_dsl.path, steps: @schema_dsl.steps, macros: @schema_dsl.macros,
            types: {name => member_type}
          )
        end

        def new(**options)
          Value.new(name: name, compiler: compiler, schema_dsl: schema_dsl, **options)
        end

        def inferred_type(rule)
          case rule
          when DSL
            rule.schema_dsl.types.fetch(name)
          when ::Dry::Logic::Operations::Binary
            left = inferred_type(rule.left)
            right = inferred_type(rule.right)

            if rule.is_a?(::Dry::Logic::Operations::Or)
              alternative_type(rule, left, right)
            elsif ordered_schema_composition?(rule, left, right)
              merge_types(rule.class, left, right)
            elsif rule.is_a?(::Dry::Logic::Operations::And) && same_collection?(left, right)
              merge_types(rule.class, left, right)
            else
              right || left
            end
          end
        end

        private

        def ordered_schema_composition?(rule, left, right)
          left && right && TypesMerger::SchemaIntersection.needed?(left, right) &&
            (rule.is_a?(::Dry::Logic::Operations::And) || rule.is_a?(::Dry::Logic::Operations::Implication))
        end

        def alternative_type(rule, left, right)
          # Predicates alone declare no coercion. Keep the other operand's
          # collection type so nested keys and array members still get coerced.
          unless left && right
            declared = left || right
            return declared if collection?(declared)
            return
          end

          return member_type unless member_type.meta[:default] || collection?(member_type)
          return left if left == right

          key_type = hash_key_type(left, right) || hash_key_type(right, left)
          if key_type
            TypesMerger::Alternatives.new(left, right, key_type: key_type)
          elsif (key_type = TypesMerger::SchemaAlternatives.key_type(left, right))
            rules = rule.rules.map { |operand| compiler.visit(operand.to_ast) }
            TypesMerger::SchemaAlternatives.new(left, right, key_type: key_type, rules: rules)
          else
            merge_types(::Dry::Logic::Operations::Or, left, right)
          end
        end

        def hash_key_type(type, other)
          type if type.respond_to?(:name_key_map) && !other.primitive?(EMPTY_HASH)
        end

        def collection?(type)
          type.respond_to?(:schema) || type.respond_to?(:of)
        end

        def same_collection?(left, right)
          (left.respond_to?(:name_key_map) && right.respond_to?(:name_key_map)) ||
            (left.respond_to?(:member) && right.respond_to?(:member))
        end

        def merge_types(operator, left, right)
          TypesMerger::ValueMerger.new(operator).call(left, right)
        end

        def append_macro(...)
          super
        ensure
          @scope = nil
        end
      end
    end
  end
end
