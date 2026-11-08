# frozen_string_literal: true

require "dry/types"
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

      # Open schemas can coerce successfully while dropping all the keys of
      # another branch. Try that branch when the first projection is missing a
      # required DSL key. Keep whole projections, including arrays of hashes.
      #
      # @api private
      class Alternatives < ::Dry::Types::Sum
        attr_reader :key_type

        def initialize(left, right, key_type:, **options)
          @key_type = key_type
          super(left, right, key_type: key_type, **options)
        end

        # dry-types' printer dispatches on exact composition classes.
        def to_s = (left | right).to_s
        alias_method :inspect, :to_s

        def call_safe(input, &block) = coerce(input) { right.call_safe(input, &block) }
        def call_unsafe(input) = coerce(input) { right.call_unsafe(input) }

        def try(input, &block)
          first = left.try(input) { return right.try(input, &block) }
          return first unless missing_key?(left, first.input)

          second = right.try(input) { return first }
          missing_key?(right, second.input) ? first : second
        end

        private

        def coerce(input)
          first = left.call_safe(input) { return yield }
          return first unless missing_key?(left, first)

          second = right.call_safe(input) { return first }
          missing_key?(right, second) ? first : second
        end

        def missing_key?(type, input)
          return unless input.is_a?(::Hash) || input.is_a?(::Array)

          type = OptionalType[type]&.value_type || type

          if type.is_a?(Alternatives)
            missing_key?(type.left, input) && missing_key?(type.right, input)
          elsif input.is_a?(::Hash) && type.respond_to?(:name_key_map)
            type.options.fetch(:schema_required_keys, EMPTY_ARRAY).any? { |key| !input.key?(key) } ||
              input.any? do |name, value|
                key = type.name_key_map[name]
                key && missing_key?(key.type, value)
              end
          elsif input.is_a?(::Array) && type.respond_to?(:member)
            input.any? { |value| missing_key?(type.member, value) }
          end
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
            key_type = merge_collection(key_type(left), key_type(right))
            key_type ? Alternatives.new(left, right, key_type: key_type) : (left | right)
          else
            merge_ordered(left, right)
          end
        end

        private

        def key_type(type)
          type.is_a?(Alternatives) ? type.key_type : type
        end

        # Rebuild nested collections using the existing constructors. Scalar
        # arrays fall back to the operation on the arrays as a whole.
        def merge_collection(left, right)
          if left.respond_to?(:name_key_map) && right.respond_to?(:name_key_map)
            return unless mergeable_hashes?(left, right)

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

        def mergeable_hashes?(left, right)
          if @operator == :|
            return false unless open_schema?(left) && open_schema?(right)
          elsif left.is_a?(::Dry::Types::Schema) && right.is_a?(::Dry::Types::Schema)
            return true
          end

          # An ordered merge with different constructors uses the right-hand
          # type as a whole, as it does for scalar types.
          same_coercer?(hash_coercer(left), hash_coercer(right))
        end

        def hash_coercer(type)
          type = type.type while type.is_a?(::Dry::Types::Constrained)
          type.clear.with(schema_required_keys: nil)
        end

        def open_schema?(schema)
          !schema.strict? && schema.keys.none? { |key| key.required? || key.default? }
        end

        def merge_optional_collection(left, right)
          lhs = OptionalType[left]
          rhs = OptionalType[right]
          return unless lhs || rhs
          return if lhs && rhs && !same_coercer?(lhs.nil_type, rhs.nil_type)

          merge_collection(lhs&.value_type || left, rhs&.value_type || right)
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
