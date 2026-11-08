# frozen_string_literal: true

module Dry
  module Schema
    # Combines multiple logical operations into a single type, taking into
    # account the type of logical operation (or, and, implication) and the
    # underlying types (schemas, nominals, etc.)
    #
    # @api private
    class TypesMerger
      # @api private
      class ValueMerger
        attr_reader :op_class
        attr_reader :old
        attr_reader :new

        # @api private
        def initialize(op_class, old, new)
          @op_class = op_class
          @old = old
          @new = new
        end

        # @api private
        def call
          if op_class <= ::Dry::Logic::Operations::Or
            merge_or
          elsif op_class <= ::Dry::Logic::Operations::And
            merge_and
          elsif op_class <= ::Dry::Logic::Operations::Implication
            merge_implication
          else
            raise ::ArgumentError, <<~MESSAGE
              Can't merge operations, op_class=#{op_class}
            MESSAGE
          end
        end

        private

        # @api private
        def merge_or
          return old if old == new

          merge_or_structure(old, new) || (old | new)
        end

        # @api private
        def merge_or_structure(left, right)
          if left.is_a?(::Dry::Types::Sum) || right.is_a?(::Dry::Types::Sum)
            merge_optional_structure(left, right)
          elsif left.respond_to?(:member) && right.respond_to?(:member) && same_coercer?(left.of(right.member), right)
            member = merge_or_structure(left.member, right.member)
            left.of(member) if member
          elsif mergeable_schema?(left) && mergeable_schema?(right) && same_coercer?(left.clear, right.clear)
            # Both schemas accept a hash even if none of their keys match.
            # Coerce their combined keys so the first branch cannot discard the second branch's input.
            merge_schemas(left, right)
          end
        end

        # @api private
        def merge_optional_structure(left, right)
          left_nil, left_value = optional_branches(left)
          right_nil, right_value = optional_branches(right)
          return unless left_nil || right_nil
          return if left_nil && right_nil && !same_coercer?(left_nil, right_nil)

          value = merge_or_structure(left_value || left, right_value || right)
          return unless value

          # The first matching coercer wins. An empty Params string can
          # become either nil or an empty collection depending on branch order.
          nil_type = left_nil || right_nil
          type = left_nil && left.left == left_nil ? nil_type | value : value | nil_type
          type.meta(value.meta.merge(maybe: true))
        end

        # DSL key metadata does not change how the collection coerces its members.
        def same_coercer?(left, right)
          left == right || left.meta(required: false, maybe: false) == right.meta(required: false, maybe: false)
        end

        # @api private
        def mergeable_schema?(type)
          type.respond_to?(:name_key_map) && !type.strict? &&
            type.keys.none? { |key| key.required? || key.default? }
        end

        # @api private
        def merge_ordered
          return old if old == new

          old_nil, old_value = optional_branches(old)
          new_nil, new_value = optional_branches(new)
          if old_nil && new_nil && same_coercer?(old_nil, new_nil)
            value = merge_values(old_value, new_value)
            return old.left == old_nil ? old_nil | value : value | old_nil
          end

          unwrapped_old, old_rule = unwrap_type(old)
          unwrapped_new, new_rule = unwrap_type(new)

          type = merge_unwrapped_types(unwrapped_old, unwrapped_new)
          unless type
            return op_class <= ::Dry::Logic::Operations::And ? old & new : old > new
          end

          rule = [old_rule, new_rule].compact.reduce { op_class.new(_1, _2) }

          type = ::Dry::Types::Constrained.new(type, rule: rule) if rule

          type
        end

        alias_method :merge_and, :merge_ordered
        alias_method :merge_implication, :merge_ordered

        # @api private
        def merge_unwrapped_types(left, right)
          if left.is_a?(::Dry::Types::Composition) || right.is_a?(::Dry::Types::Composition)
            # For conjunction, coerce to the single primitive before checking both rules.
            if op_class <= ::Dry::Logic::Operations::And
              return right if left.is_a?(::Dry::Types::Sum) && right.respond_to?(:primitive)
              return left if right.is_a?(::Dry::Types::Sum) && left.respond_to?(:primitive)
            end

            return
          end

          structure = merge_structure(left, right)
          return structure if structure
          return right if generic_for?(left, right)
          return left if generic_for?(right, left)

          merge_equivalent_types(left, right)
        end

        # @api private
        def merge_structure(left, right)
          if left.respond_to?(:name_key_map) && right.respond_to?(:name_key_map)
            merge_schemas(left, right)
          elsif left.respond_to?(:member) && right.respond_to?(:member) && same_coercer?(left.of(right.member), right)
            member = merge_structure(left.member, right.member)
            left.of(member) if member
          end
        end

        # @api private
        def generic_for?(type, other)
          type.is_a?(::Dry::Types::AnyClass) ||
            (type.respond_to?(:schema) && other.respond_to?(:name_key_map)) ||
            (type.respond_to?(:of) && !type.respond_to?(:member) && other.respond_to?(:member))
        end

        # @api private
        def merge_schemas(left, right)
          keys = left.name_key_map.merge(right.name_key_map) do |name, lkey, rkey|
            type = merge_values(lkey.type, rkey.type)
            ::Dry::Types::Schema::Key.new(type, name, required: lkey.required? || rkey.required?)
          end
          left.schema(keys.values)
        end

        # @api private
        def merge_values(left, right)
          self.class.new(op_class, left, right).call
        end

        # @api private
        def merge_equivalent_types(unwrapped_old, unwrapped_new)
          if unwrapped_old.primitive <= unwrapped_new.primitive
            unwrapped_new
          elsif unwrapped_new.primitive <= unwrapped_old.primitive
            unwrapped_old
          else
            raise ::ArgumentError, <<~MESSAGE
              Can't merge types, unwrapped_old=#{unwrapped_old.inspect}, unwrapped_new=#{unwrapped_new.inspect}
            MESSAGE
          end
        end

        # @api private
        def unwrap_type(type)
          rules = []

          loop do
            rules << type.rule if type.respond_to?(:rule)

            if (branches = optional_branches(type))
              type = branches.last
            elsif type.is_a?(::Dry::Types::Decorator)
              type = type.type
            else
              break
            end
          end

          [type, rules.reduce(:&)]
        end

        # @api private
        def optional_branches(type)
          return unless type.is_a?(::Dry::Types::Sum)

          if type.left.respond_to?(:primitive) && type.left.primitive == ::NilClass
            [type.left, type.right]
          elsif type.right.respond_to?(:primitive) && type.right.primitive == ::NilClass
            [type.right, type.left]
          end
        end
      end

      # @api private
      def call(op_class, lhs, rhs)
        lhs.merge(rhs) do |_k, old, new|
          ValueMerger.new(op_class, old, new).call
        end
      end
    end
  end
end
