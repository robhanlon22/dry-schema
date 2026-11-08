# frozen_string_literal: true

require "dry/schema/optional_type"

module Dry
  module Schema
    # Combines the coercion types of keys shared by logical operations.
    #
    # @api private
    class TypesMerger
      def call(op_class, lhs, rhs)
        merger = nil
        lhs.merge(rhs) do |_, left, right|
          merger ||= ValueMerger.new(op_class)
          merger.call(left, right)
        end
      end

      # @api private
      class ValueMerger
        def initialize(op_class)
          @op_class = op_class
          @operator =
            if op_class <= ::Dry::Logic::Operations::Or
              :|
            elsif op_class <= ::Dry::Logic::Operations::And
              :&
            elsif op_class <= ::Dry::Logic::Operations::Implication
              :>
            else
              raise ::ArgumentError, "Can't merge operations, op_class=#{op_class}\n"
            end
        end

        def call(left, right)
          return left if left == right

          if @operator == :|
            merge_collection(left, right) || (left | right)
          else
            merge_ordered(left, right)
          end
        end

        private

        # Rebuild nested collections using the existing constructors. Scalar
        # arrays fall back to the operation on the arrays as a whole.
        def merge_collection(left, right)
          if left.respond_to?(:name_key_map) && right.respond_to?(:name_key_map)
            return if @operator == :| && !compatible_alternatives?(left, right)

            keys = left.name_key_map.merge(right.name_key_map) do |name, lkey, rkey|
              type = call(lkey.type, rkey.type)
              ::Dry::Types::Schema::Key.new(type, name, required: lkey.required? || rkey.required?)
            end
            left.schema(keys.values)
          elsif left.respond_to?(:member) && right.respond_to?(:member)
            return unless same_coercer?(left.of(right.member), right)

            member = merge_collection(left.member, right.member)
            left.of(member) if member
          elsif @operator == :|
            merge_optional_collection(left, right)
          end
        end

        # An open schema can accept a hash and discard all of its keys before
        # a later OR branch sees them. Combining the keys is safe only when
        # neither schema requires or supplies keys and both coerce the same way.
        def compatible_alternatives?(left, right)
          open_schema?(left) && open_schema?(right) && same_coercer?(left.clear, right.clear)
        end

        def open_schema?(schema)
          !schema.strict? && schema.keys.none? { |key| key.required? || key.default? }
        end

        def merge_optional_collection(left, right)
          lhs = OptionalType[left]
          rhs = OptionalType[right]
          optional = lhs || rhs
          return unless optional
          return if lhs && rhs && !same_coercer?(lhs.nil_type, rhs.nil_type)

          value = merge_collection(lhs&.value_type || left, rhs&.value_type || right)
          return unless value

          # A Params empty string can coerce to nil or an empty collection.
          # Keep whichever coercer the first alternative would have tried first.
          optional.with_value(value, nil_first: lhs && lhs.nil_first?).meta(value.meta.merge(maybe: true))
        end

        # DSL key metadata does not change a type's coercion.
        def same_coercer?(left, right)
          left == right || left.meta(required: false, maybe: false) == right.meta(required: false, maybe: false)
        end

        def merge_ordered(left, right)
          lhs = OptionalType[left]
          rhs = OptionalType[right]
          if lhs && rhs && same_coercer?(lhs.nil_type, rhs.nil_type)
            return lhs.with_value(call(lhs.value_type, rhs.value_type))
          end

          left_type, left_rule = unwrap_type(left)
          right_type, right_rule = unwrap_type(right)
          type = common_type(left_type, right_type)
          return left.public_send(@operator, right) unless type

          rule = [left_rule, right_rule].compact.reduce { @op_class.new(_1, _2) }
          rule ? ::Dry::Types::Constrained.new(type, rule: rule) : type
        end

        def common_type(left, right)
          # A conjunction with a scalar can coerce to that primitive before
          # evaluating both rules. Other compositions supply their own coercion.
          if @operator == :&
            return right if left.is_a?(::Dry::Types::Sum) && right.respond_to?(:primitive)
            return left if right.is_a?(::Dry::Types::Sum) && left.respond_to?(:primitive)
          end
          return if left.is_a?(::Dry::Types::Composition) || right.is_a?(::Dry::Types::Composition)

          collection = merge_collection(left, right)
          return collection if collection
          return right if generic_for?(left, right)
          return left if generic_for?(right, left)
          return right if left.primitive <= right.primitive
          return left if right.primitive <= left.primitive

          raise ::ArgumentError, "Can't merge types, unwrapped_old=#{left.inspect}, unwrapped_new=#{right.inspect}\n"
        end

        def generic_for?(type, other)
          type.is_a?(::Dry::Types::AnyClass) ||
            (type.respond_to?(:schema) && other.respond_to?(:name_key_map)) ||
            (type.respond_to?(:of) && !type.respond_to?(:member) && other.respond_to?(:member))
        end

        def unwrap_type(type)
          rules = []
          loop do
            rules << type.rule if type.respond_to?(:rule)

            if (optional = OptionalType[type])
              type = optional.value_type
            elsif type.is_a?(::Dry::Types::Decorator)
              type = type.type
            else
              return [type, rules.reduce(:&)]
            end
          end
        end
      end
    end
  end
end
