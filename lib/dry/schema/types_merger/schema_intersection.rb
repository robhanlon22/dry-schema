# frozen_string_literal: true

require "dry/schema/types_merger/projected_type"

module Dry
  module Schema
    class TypesMerger
      # An enclosing conjunction or implication needs the coercions from both
      # operands. A nested OR must choose its projection before they are joined.
      # @api private
      class SchemaIntersection < ::Dry::Types::Intersection
        include ProjectedType

        def self.needed?(left, right)
          (left.is_a?(::Dry::Types::Composition) && left.respond_to?(:key_type)) ||
            (right.is_a?(::Dry::Types::Composition) && right.respond_to?(:key_type))
        end

        def key_type = SchemaAlternatives.key_type(left, right)

        def to_s = (left & right).to_s
        alias_method :inspect, :to_s

        def try(input)
          first = left.try(input)
          second = right.try(input)
          output = merge_projections(input, first.input, second.input, carry_failures: true) do |source, a, b|
            b.eql?(source) ? a : b
          end

          if first.success? && second.success?
            ::Dry::Types::Result::Success.new(output)
          else
            error = first.failure? ? first.error : second.error
            failure = ::Dry::Types::Result::Failure.new(output, error)
            block_given? ? yield(failure) : failure
          end
        end
      end
    end
  end
end
