# frozen_string_literal: true

module Dry
  module Schema
    module Extensions
      module Hints
        # Adds support for processing [:hint, ...] nodes produced by dry-logic
        #
        # @api private
        module MessageCompilerMethods
          HINT_TYPE_EXCLUSION = %i[
            key? nil? bool? str? int? float? decimal?
            date? date_time? time? hash? array?
          ].freeze

          HINT_OTHER_EXCLUSION = %i[format? filled?].freeze

          # @api private
          attr_reader :hints

          # @api private
          def initialize(*, **)
            super
            @hints = @options.fetch(:hints, true)
          end

          # @api private
          def hints?
            hints.equal?(true)
          end

          # @api private
          def filter(messages, opts)
            Hints.select_messages([messages]) { |msg| !exclude?(msg, opts) }.uniq
          end

          # @api private
          def exclude?(message, opts)
            HINT_OTHER_EXCLUSION.include?(message.predicate) ||
              (HINT_TYPE_EXCLUSION.include?(message.predicate) && !opts.key_failure?(message.path))
          end

          # @api private
          def message_type(options)
            options[:message_type].equal?(:hint) ? Hint : Message
          end

          # @api private
          def visit_hint(node, opts)
            if hints?
              filter(visit(node, opts.(message_type: :hint)), opts)
            end
          end

          # @api private
          def visit_predicate(node, opts)
            message = super
            opts.current_messages << message
            message
          end

          # @api private
          def visit_each(_node, _opts)
            # TODO: we can still generate a hint for elements here!
            []
          end
        end
      end
    end
  end
end
