# frozen_string_literal: true

module Dry
  module Schema
    class Message
      module Or
        # A message type used by OR operations with different paths
        #
        # @api public
        class MultiPath < Abstract
          # @api private
          def self.branch?(message)
            message.is_a?(Array) || message.is_a?(self) ||
              (message.is_a?(SinglePath) && message.schema_branch?)
          end

          # @api public
          def to_h
            @to_h ||= Path[[*root, :or]].to_h(alternatives)
          end

          # @api private
          def root
            @root ||= branches.flatten.map(&:_path).reduce(:&)
          end
          alias_method :path, :root
          alias_method :_path, :root

          # @api private
          def alternatives
            @alternatives ||= branches.flat_map do |branch|
              if branch.is_a?(MultiPath) && branch.root == root
                branch.alternatives
              else
                # Assemble the branch with its original paths before removing
                # the prefix shared by all the alternatives.
                errors = MessageSet.new([branch].flatten).to_h
                [root.keys.empty? ? errors : errors.dig(*root.keys)]
              end
            end
          end

          private

          def branches
            @branches ||= [left, right].each do |branch|
              unless self.class.branch?(branch)
                raise ArgumentError, "#{branch.inspect} is of unknown type #{branch.class.inspect}"
              end
            end
          end
        end
      end
    end
  end
end
