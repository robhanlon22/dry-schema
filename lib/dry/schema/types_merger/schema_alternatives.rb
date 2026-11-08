# frozen_string_literal: true

require "dry/schema/types_merger"
require "dry/schema/types_merger/projected_type"

module Dry
  module Schema
    class TypesMerger
      # Coerce each branch before applying its validation rule. A schema can
      # accept a hash while silently dropping keys owned by another branch.
      # @api private
      class SchemaAlternatives < Alternatives
        include ProjectedType

        def self.key_type(left, right)
          # The DSL compiles the complete key map from both operands. A
          # representative type suffices to identify a structured alternative.
          [key_shape(left), key_shape(right)].find { |shape| structured?(shape) }
        end

        def self.key_shape(type)
          type = type.key_type if type.is_a?(::Dry::Types::Composition) && type.respond_to?(:key_type)
          OptionalType[type]&.value_type || type
        end
        private_class_method :key_shape

        def self.structured?(type)
          type.respond_to?(:name_key_map) || (type.respond_to?(:member) && structured?(key_shape(type.member)))
        end
        private_class_method :structured?

        attr_reader :choices, :branches, :failure_tree

        def initialize(left, right, rules:, **options)
          @branches = rules.map(&:to_ast)
          @choices = []
          @failure_tree = [left, right].zip(rules).map do |type, rule|
            if type.is_a?(SchemaAlternatives) && rule.to_ast == [:or, type.branches]
              offset = @choices.size
              @choices.concat(type.choices)
              remap(type.failure_tree, offset)
            else
              @choices << [type, rule]
              @choices.size - 1
            end
          end
          super(left, right, rules: rules, **options)
        end

        def try(input)
          results = choices.map { |type, _| type.try(input) }
          result =
            if results.all? { |r| r.input.eql?(results.first.input) }
              results.find(&:success?) || results.first
            else
              select(input, results)
            end
          result.failure? && block_given? ? yield(result) : result
        end

        private

        def remap(node, offset)
          node.is_a?(::Array) ? node.map { |child| remap(child, offset) } : node + offset
        end

        def select(input, results)
          validations = validate_projections(results)
          accepted = results.each_index.select { |i| results[i].success? && validations[i].success? }
          return results[accepted.first] if accepted.size == 1

          if accepted.empty?
            # Keep invalid supplied fields in the public output. Their errors
            # belong to the projections on which the predicates actually ran.
            joined = results.map(&:input).reduce { |a, b| combine(input, a, b) }
            if validations.all? { |test| test&.failure? }
              BranchFailures.record(joined, branches) do |recheck|
                # A callback may edit a domain object shared by both projections.
                tests = recheck ? validate_projections(results) : validations
                if !recheck || tests.all? { |test| test&.failure? }
                  Logic::Result.new(false) { failed_alternatives(failure_tree, tests) }
                end
              end
            end
            if results.all?(&:failure?)
              ::Dry::Types::Result::Failure.new(joined, results.first.error)
            else
              ::Dry::Types::Result::Success.new(joined)
            end
          else
            combine_accepted(input, accepted, results)
          end
        end

        def validate_projections(results)
          results.map.with_index do |result, i|
            value = result.input
            choices[i].last.call(value) if result.success? || value.is_a?(::Hash) || value.is_a?(::Array)
          end
        end

        def combine_accepted(input, accepted, results)
          joined = accepted.map { |i| results[i].input }.reduce { |a, b| combine(input, a, b) }
          if accepted.any? { |i| joined.eql?(results[i].input) || choices[i].last.call(joined).success? }
            return ::Dry::Types::Result::Success.new(joined)
          end

          # Size constraints can rule out combining otherwise valid hashes.
          # Key normalization follows declaration order; compare field names
          # directly when selecting a whole projection, prioritizing input keys.
          accepted.map { |i| results[i] }.reduce do |a, b|
            prefer_second?(input, a.input, b.input) ? b : a
          end
        end

        def failed_alternatives(node, validations)
          if node.is_a?(::Array)
            [:or, node.map { |child| failed_alternatives(child, validations) }]
          else
            validations.fetch(node).to_ast
          end
        end

        def combine(input, a, b)
          merge_projections(input, a, b) { |source, x, y| y.eql?(source) ? y : x }
        end

        def prefer_second?(input, a, b)
          if a.is_a?(::Hash) && b.is_a?(::Hash)
            source = input.is_a?(::Hash) ? input : EMPTY_HASH
            keys = (a.keys | b.keys).sort_by { |key| [source.key?(key) ? 0 : 1, key.to_s] }
            keys.each do |key|
              return b.key?(key) if a.key?(key) != b.key?(key)

              preference = prefer_second?(source.fetch(key, Undefined), a[key], b[key])
              return preference unless preference.nil?
            end
          elsif a.is_a?(::Array) && b.is_a?(::Array)
            return b.size > a.size unless a.size == b.size
            a.each_index do |i|
              value = input.is_a?(::Array) ? input[i] : Undefined
              preference = prefer_second?(value, a[i], b[i])
              return preference unless preference.nil?
            end
          elsif input.eql?(a) != input.eql?(b)
            return input.eql?(b)
          end
          nil
        end
      end
    end
  end
end
