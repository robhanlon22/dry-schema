# frozen_string_literal: true

module Dry
  module Schema
    # The value coercer runs before the rule applier. When both projections of
    # a schema OR fail, keep their errors paired with the values they checked.
    # @api private
    class BranchFailures
      KEY = :__dry_schema_branch_failures__

      def self.within(enabled, steps)
        previous = Thread.current[KEY]
        return yield unless enabled || previous

        begin
          Thread.current[KEY] = enabled ? new(steps) : nil
          yield
        ensure
          Thread.current[KEY] = previous
        end
      end

      def self.record(value, rules, &block)
        Thread.current[KEY]&.record(value, rules, &block)
      end

      def self.carry(source, value)
        Thread.current[KEY]&.carry(source, value)
      end

      def self.lookup(value, rules)
        Thread.current[KEY]&.lookup(value, rules)
      end

      def initialize(steps)
        @watch_changes = steps.after_steps.key?(:value_coercer) || steps.before_steps.key?(:rule_applier)
      end

      def record(value, rules, &failure)
        @entries ||= {}.compare_by_identity
        failures = (@entries[value] ||= {})
        failures[rules] = [(@watch_changes && snapshot(value)), failure]
      end

      def carry(source, value)
        return unless @entries && (from = @entries[source])
        return if source.equal?(value)

        failures = (@entries[value] ||= {})
        from.each do |rules, (_, failure)|
          failures[rules] = [(@watch_changes && snapshot(value)), failure]
        end
      end

      def lookup(value, rules)
        if @entries && (entry = @entries[value]&.fetch(rules, nil))
          original, failure = entry
          failure.call(@watch_changes) if !@watch_changes || original.eql?(value)
        end
      end

      private

      # Callbacks between coercion and validation can edit a value in place.
      def snapshot(value, seen = {}.compare_by_identity)
        return seen[value] if seen.key?(value)

        case value
        when ::Hash
          copy = seen[value] = value.dup
          copy.transform_values! { |item| snapshot(item, seen) }
        when ::Array
          copy = seen[value] = []
          value.each { |item| copy << snapshot(item, seen) }
          copy
        when ::String
          value.dup
        else
          value
        end
      end

      class Or < ::Dry::Logic::Operations::Or
        def call(value)
          BranchFailures.lookup(value, options[:branches]) || super
        end

        def [](value)
          !BranchFailures.lookup(value, options[:branches]) && super
        end
      end
    end
  end
end
