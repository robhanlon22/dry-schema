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
          msgs = [left, right].flatten

          if msgs.none? { _1.is_a?(MultiPath) } && msgs.map(&:path).uniq.size == 1
            SinglePath.new(left, right, messages)
          elsif MultiPath.branch?(right)
            if MultiPath.branch?(left)
              MultiPath.new(left, right)
            else
              right
            end
          else
            msgs.max_by(&:_path)
          end
        end
      end
    end
  end
end
