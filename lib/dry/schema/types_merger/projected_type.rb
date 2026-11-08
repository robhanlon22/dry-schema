# frozen_string_literal: true

module Dry
  module Schema
    class TypesMerger
      # Common dry-types calls and structural merging for schema projections.
      # @api private
      module ProjectedType
        def call_safe(input)
          try(input) { |failure| return yield(failure.input) }.input
        end

        def call_unsafe(input)
          try(input) { |failure| raise failure.error }.input
        end

        private

        def merge_projections(input, left, right, carry_failures: false, &conflict)
          output =
            if left.eql?(right)
              left
            elsif left.is_a?(::Hash) && right.is_a?(::Hash)
              left.merge(right) do |key, a, b|
                source = input.is_a?(::Hash) ? input.fetch(key, Undefined) : Undefined
                merge_projections(source, a, b, carry_failures: carry_failures, &conflict)
              end
            elsif left.is_a?(::Array) && right.is_a?(::Array) && left.size == right.size
              left.map.with_index do |a, i|
                source = input.is_a?(::Array) ? input[i] : Undefined
                merge_projections(source, a, right[i], carry_failures: carry_failures, &conflict)
              end
            else
              yield(input, left, right)
            end

          if carry_failures
            BranchFailures.carry(left, output) unless left.equal?(output)
            BranchFailures.carry(right, output) unless right.equal?(output)
          end
          output
        end
      end
    end
  end
end
