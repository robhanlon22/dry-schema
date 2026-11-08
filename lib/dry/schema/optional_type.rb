# frozen_string_literal: true

module Dry
  module Schema
    # A sum with a nil branch. Branch order matters because dry-types returns
    # the first successful coercion (e.g. a Params array and nil both accept "").
    #
    # @api private
    class OptionalType < ::Data.define(:nil_type, :value_type, :nil_first?)
      def self.[](type)
        with_nil_branch(type) { |branch| branch.respond_to?(:primitive) && branch.primitive == ::NilClass }
      end

      def self.with_nil_branch(type)
        return unless type.is_a?(::Dry::Types::Sum)

        if yield(type.left)
          new(type.left, type.right, true)
        elsif yield(type.right)
          new(type.right, type.left, false)
        end
      end

      def with_value(type, nil_first: nil_first?)
        nil_first ? nil_type | type : type | nil_type
      end
    end
  end
end
