# frozen_string_literal: true

require "dry/schema/constants"

module Dry
  module Schema
    # Represents a list of keys defined by the DSL
    #
    # KeyMap objects expose an API for introspecting schema keys and the ability
    # to rebuild an input hash using configured coercer function.
    #
    # Instances of this class are used as the very first step by the schema processors.
    #
    # @api public
    class KeyMap
      extend ::Dry::Core::Cache

      include ::Dry.Equalizer(:keys)
      include ::Enumerable

      # @return [Array<Key>] A list of defined key objects
      attr_reader :keys

      # Coerce a list of key specs into a key map
      #
      # @example
      #   KeyMap[:id, :name]
      #   KeyMap[:title, :artist, tags: [:name]]
      #   KeyMap[:title, :artist, [:tags]]
      #   KeyMap[[:rows, [:id], 2]] # arrays of arrays of hashes with an :id key
      #   KeyMap[[:item, {0 => [:id], 1 => [:name]}]] # a hash or an array of hashes
      #
      # @return [KeyMap]
      #
      # @api public
      def self.[](*keys)
        new(keys)
      end

      # Build new, or returned a cached instance of a key map
      #
      # @param [Array<Symbol>, Array, Hash<Symbol=>Array>] args
      #
      # @return [KeyMap]
      def self.new(*args)
        fetch_or_store(*args) { super }
      end

      # Set key objects
      #
      # @api private
      def initialize(keys)
        @keys = keys.map { |key|
          case key
          when Hash
            root, rest = key.flatten
            Key::Hash[root, members: KeyMap[*rest]]
          when Array
            root, rest = key
            if rest.is_a?(Hash) && !rest.empty? && rest.keys.all? { |depth| depth.is_a?(Integer) && depth >= 0 }
              Key::Variants[root, shapes: rest.transform_values { |members| KeyMap[*members] }]
            else
              Key::Array[root, member: KeyMap[*rest], depth: key.fetch(2, 1)]
            end
          when Key
            key
          else
            Key[key]
          end
        }
      end

      # Write a new hash based on the source hash
      #
      # @param [Hash] source The source hash
      # @param [Hash] target The target hash
      #
      # @return [Hash]
      #
      # @api public
      def write(source, target = EMPTY_HASH.dup)
        each { |key| key.write(source, target) }
        target
      end

      # Return a new key map that is configured to coerce keys using provided coercer function
      #
      # @return [KeyMap]
      #
      # @api public
      def coercible(&coercer)
        self.class.new(map { |key| key.coercible(&coercer) })
      end

      # Return a new key map with stringified keys
      #
      # A stringified key map is suitable for reading hashes with string keys
      #
      # @return [KeyMap]
      #
      # @api public
      def stringified
        self.class.new(map(&:stringified))
      end

      # @api private
      def to_dot_notation
        @to_dot_notation ||= map(&:to_dot_notation).flatten
      end

      # Only alternatives with competing array depths need the raw input's
      # exact dimensions. Ordinary array constructors may flatten their input.
      # @api private
      def variant_paths
        @variant_paths ||= each_with_object({}) do |key, paths|
          paths[key.name.to_s] = true if key.is_a?(Key::Variants)
          key.shapes.each do |depth, members|
            depth = 1 if depth.positive? && !key.is_a?(Key::Variants)
            prefix = key.name.to_s + "[]" * depth + DOT
            members.variant_paths.each_key { |path| paths[prefix + path] = true }
          end
        end
      end

      # Iterate over keys
      #
      # @api public
      def each(&)
        keys.each(&)
      end

      # Return a new key map merged with the provided one
      #
      # @param [KeyMap, Array] other Either a key map or an array with key specs
      #
      # @return [KeyMap]
      def +(other)
        self.class.new(keys + other.to_a)
      end

      # Normalize the nested keys admitted by either alternative.
      # @api private
      def |(other)
        lhs = keys.to_h { |key| [key.id, key] }
        rhs = other.to_h { |key| [key.id, key] }
        self.class.new(lhs.merge(rhs) { |_, left, right| left | right }.values)
      end

      # Return a string representation of a key map
      #
      # @return [String]
      def inspect
        "#<#{self.class}[#{keys.map(&:dump).map(&:inspect).join(", ")}]>"
      end

      # Dump keys to their spec format
      #
      # @return [Array]
      def dump
        keys.map(&:dump)
      end
    end
  end
end
