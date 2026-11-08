# frozen_string_literal: true

require "dry/schema/extensions/hints/compiler_methods"
require "dry/schema/extensions/hints/message_compiler_methods"
require "dry/schema/extensions/hints/message_set_methods"
require "dry/schema/extensions/hints/result_methods"

module Dry
  module Schema
    # Hint-specific Message extensions
    #
    # @see Message
    #
    # @api public
    class Message
      # Hints extension for Or messages
      #
      # @see Message::Or
      #
      # @api public
      module Or
        class Abstract
          # @api private
          def hint?
            [left, right].flatten.all?(&:hint?)
          end
        end
      end

      # @api private
      def hint?
        false
      end
    end

    # A hint message sub-type
    #
    # @api private
    class Hint < Message
      # @api private
      def hint?
        true
      end
    end

    # Hints extensions
    module Extensions
      # @api private
      module Hints
        def self.select_messages(messages, &block)
          messages.flatten.flat_map do |message|
            if message.is_a?(Message::Or::Abstract)
              select_alternatives(message, &block)
            else
              yield(message) ? [message] : EMPTY_ARRAY
            end
          end
        end

        # Keep the disjunction when both alternatives contribute a hint.
        def self.select_alternatives(message, &block)
          left = select_messages([message.left], &block)
          right = select_messages([message.right], &block)
          return right if left.empty?
          return left if right.empty?

          if message.is_a?(Message::Or::SinglePath)
            Message::Or::SinglePath.new(left, right, message.messages)
          else
            Message::Or::MultiPath.new(left, right)
          end
        end
        private_class_method :select_alternatives
      end

      Compiler.prepend(Hints::CompilerMethods)
      MessageCompiler.prepend(Hints::MessageCompilerMethods)
      MessageSet.prepend(Hints::MessageSetMethods)
      Result.prepend(Hints::ResultMethods)
    end
  end
end
