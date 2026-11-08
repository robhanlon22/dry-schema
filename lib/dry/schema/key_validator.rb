# frozen_string_literal: true

require "dry/initializer"
require "dry/schema/constants"

module Dry
  module Schema
    # @api private
    class KeyValidator
      extend ::Dry::Initializer

      MULTI_INDEX_REGEX = /(?:\[\d+\])+/
      INDEX_REGEX = /\[\d+\]/
      DIGIT_REGEX = /\A\d+\z/
      BRACKETS = "[]"

      # @api private
      option :key_map

      # @api private
      def call(result)
        input = result.to_h

        input_paths = key_paths(input)
        key_paths = key_map.to_dot_notation.sort

        original_input = nil
        input_paths.each do |path|
          error_path = validate_path(key_paths, path)

          next unless error_path

          # Later processing steps replace the contents of the result hash.
          original_input ||= input.dup
          result.add_error([:unexpected_key, [error_path, original_input]])
        end

        result
      end

      private

      # @api private
      def validate_path(key_paths, path)
        if path[INDEX_REGEX]
          key = normalize_indices(path)
          if none_key_paths_match?(key_paths, key)
            arr = path.gsub(INDEX_REGEX) { ".#{_1[1...-1]}" }
            arr.split(DOT).map { DIGIT_REGEX.match?(_1) ? Integer(_1, 10) : _1.to_sym }
          end
        elsif none_key_paths_match?(key_paths, path)
          path
        end
      end

      def normalize_indices(path)
        variants = key_map.variant_paths
        return path.gsub(MULTI_INDEX_REGEX, BRACKETS) if variants.empty? || !path.include?("][")

        normalized = +""
        offset = 0
        path.scan(MULTI_INDEX_REGEX) do |indices|
          match = Regexp.last_match
          normalized << path[offset...match.begin(0)]
          normalized << (variants.key?(normalized) ? indices.gsub(INDEX_REGEX, BRACKETS) : BRACKETS)
          offset = match.end(0)
        end
        normalized << path[offset..]
      end

      # @api private
      def none_key_paths_match?(key_paths, path)
        !any_key_paths_match?(key_paths, path)
      end

      # @api private
      def any_key_paths_match?(key_paths, path)
        find_path(key_paths, path, false) ||
          find_path(key_paths, path + DOT, true) ||
          find_path(key_paths, path + BRACKETS, true)
      end

      # @api private
      def find_path(key_paths, path, prefix_match)
        key = key_paths.bsearch { |key_path| key_path >= path }
        prefix_match ? key&.start_with?(path) : key == path
      end

      # @api private
      def key_paths(hash)
        hash.flat_map { |key, value|
          case value
          when ::Hash
            if value.empty?
              [key.to_s]
            else
              [key].product(key_paths(hash[key])).map { _1.join(DOT) }
            end
          when ::Array
            hashes_or_arrays = hashes_or_arrays(value)

            if hashes_or_arrays.empty?
              [key.to_s]
            else
              traverse_array(value).map { |sub_path| [key, sub_path].join("") }
            end
          else
            key.to_s
          end
        }
      end

      # @api private
      def hashes_or_arrays(xs)
        xs.select { |x|
          (x.is_a?(::Array) || x.is_a?(::Hash)) && !x.empty?
        }
      end

      # @api private
      def traverse_array(arr)
        arr.each_with_index.flat_map do |el, idx|
          case el
          when ::Hash
            key_paths(el).map { ["[#{idx}]", *_1].join(DOT) }
          when ::Array
            traverse_array(el).map { ["[#{idx}]", *_1].join("") }
          else
            []
          end
        end
      end
    end
  end
end
