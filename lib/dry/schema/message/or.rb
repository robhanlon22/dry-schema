# frozen_string_literal: true

module Dry
  module Schema
    # Message objects used by message sets
    #
    # @api public
    class Message
      module Or
        # @api private
        def self.[](left, right, messages)
          errors = [left, right].flatten

          if errors.none?(MultiPath) && errors.map(&:path).uniq.size == 1
            return SinglePath.new(left, right, messages)
          end
          return errors.max_by(&:_path) unless schema_branch?(right)

          schema_branch?(left) ? MultiPath.new(left, right) : right
        end

        # A schema can produce one translated message and still be an
        # alternative in an enclosing OR.
        # @api private
        def self.schema_branch?(errors)
          errors.is_a?(Array) || errors.is_a?(MultiPath) ||
            (errors.is_a?(SinglePath) && errors.schema_branch?)
        end
      end
    end
  end
end
