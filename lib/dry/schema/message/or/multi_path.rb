# frozen_string_literal: true

module Dry
  module Schema
    class Message
      module Or
        # A message type used by OR operations with different paths
        #
        # @api public
        class MultiPath < Abstract
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
                [branch_errors(branch)]
              end
            end
          end

          private

          def branch_errors(branch)
            MessageSet[[branch]].merge_messages do |message|
              # A nested disjunction with its own root retains its absolute
              # location. Ordinary failures are relative to this alternative.
              if root.keys.empty? || (message.is_a?(MultiPath) && message.root != root)
                message.to_h
              else
                message.to_h.dig(*root.keys)
              end
            end
          end

          def branches
            @branches ||= [left, right].each do |branch|
              unless Or.schema_branch?(branch)
                raise ArgumentError, "#{branch.inspect} is of unknown type #{branch.class.inspect}"
              end
            end
          end
        end
      end
    end
  end
end
