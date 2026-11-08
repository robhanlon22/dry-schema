# frozen_string_literal: true

module Dry
  module Schema
    # Key objects used by key maps
    #
    # @api public
    class Key
      extend ::Dry::Core::Cache

      DEFAULT_COERCER = :itself.to_proc.freeze

      include ::Dry.Equalizer(:name, :coercer)

      # @return [Symbol] The key identifier
      attr_reader :id

      # @return [Symbol, String, Object] The actual key name expected in an input hash
      attr_reader :name

      # @return [Proc, #call] A key name coercer function
      attr_reader :coercer

      # @api private
      def self.[](name, **opts)
        new(name, **opts)
      end

      # @api private
      def self.new(*args, **kwargs)
        fetch_or_store(args, kwargs) { super }
      end

      # @api private
      def initialize(id, name: id, coercer: DEFAULT_COERCER)
        @id = id
        @name = name
        @coercer = coercer
      end

      # @api private
      def read(source)
        return unless source.is_a?(::Hash)

        if source.key?(name)
          yield(source[name])
        elsif source.key?(coerced_name)
          yield(source[coerced_name])
        end
      end

      # @api private
      def write(source, target)
        read(source) { |value| target[coerced_name] = value }
      end

      # @api private
      def coercible(&coercer)
        new(coercer: coercer)
      end

      # @api private
      def stringified
        new(name: name.to_s)
      end

      # @api private
      def to_dot_notation
        [name.to_s]
      end

      # @api private
      def new(**new_opts)
        self.class.new(id, name: name, coercer: coercer, **new_opts)
      end

      # @api private
      def dump
        name
      end

      # Hash members indexed by the array depth at which they occur.
      # @api private
      def shapes = EMPTY_HASH

      # @api private
      def |(other)
        return self if equal?(other)

        lhs = shapes
        rhs = other.shapes
        return self if rhs.empty?
        return other if lhs.empty?

        combined = lhs.merge(rhs) { |_, left, right| left | right }
        options = {name: name, coercer: coercer}
        if combined.size > 1
          Variants[id, shapes: combined, **options]
        else
          depth, map = combined.first
          depth.zero? ? Hash[id, members: map, **options] : Array[id, depth: depth, member: map, **options]
        end
      end

      private

      # @api private
      def coerced_name
        @__coerced_name__ ||= coercer[name]
      end

      def member_paths(members, depth)
        prefix = name.to_s + "[]" * depth + DOT
        members.to_dot_notation.map { |path| prefix + path }
      end

      # A specialized key type which handles nested hashes
      #
      # @api private
      class Hash < self
        include ::Dry.Equalizer(:name, :members, :coercer)

        # @api private
        attr_reader :members

        def shapes = {0 => members}

        # @api private
        def initialize(id, members:, **opts)
          super(id, **opts)
          @members = members
        end

        # @api private
        def read(source)
          super if source.is_a?(::Hash)
        end

        def write(source, target)
          read(source) { |value|
            target[coerced_name] = value.is_a?(::Hash) ? members.write(value) : value
          }
        end

        # @api private
        def coercible(&coercer)
          new(coercer: coercer, members: members.coercible(&coercer))
        end

        # @api private
        def stringified
          new(name: name.to_s, members: members.stringified)
        end

        # @api private
        def to_dot_notation
          member_paths(members, 0)
        end

        # @api private
        def dump
          {name => members.map(&:dump)}
        end
      end

      # A specialized key type which handles nested arrays
      #
      # @api private
      class Array < self
        include ::Dry.Equalizer(:name, :member, :coercer, :depth)

        attr_reader :member, :depth

        def shapes = {depth => member}

        # @api private
        def initialize(id, member:, depth: 1, **opts)
          unless depth.is_a?(::Integer) && depth.positive?
            raise ArgumentError, "array depth must be a positive integer"
          end

          super(id, **opts)
          @member = member
          @depth = depth
        end

        # @api private
        def write(source, target)
          read(source) { |value| target[coerced_name] = write_array(value, depth) }
        end

        # @api private
        def coercible(&coercer)
          new(coercer: coercer, member: member.coercible(&coercer), depth: depth)
        end

        # @api private
        def stringified
          new(name: name.to_s, member: member.stringified, depth: depth)
        end

        # @api private
        def to_dot_notation
          member_paths(member, 1)
        end

        # @api private
        def dump
          depth == 1 ? [name, member.dump] : [name, member.dump, depth]
        end

        private

        def write_array(value, remaining)
          return value unless value.is_a?(::Array)

          if remaining == 1
            value.map { |el| el.is_a?(::Hash) ? member.write(el) : el }
          else
            value.map { |el| write_array(el, remaining - 1) }
          end
        end
      end

      # Alternatives may declare hashes at different array depths under one key.
      # @api private
      class Variants < self
        include ::Dry.Equalizer(:name, :coercer, :shapes)

        attr_reader :shapes

        def initialize(id, shapes:, **options)
          super(id, **options)
          @shapes = shapes
          @last_depth = shapes.keys.max
        end

        def write(source, target)
          read(source) { |value| target[coerced_name] = write_value(value, 0) }
        end

        def coercible(&coercer)
          new(coercer: coercer, shapes: shapes.transform_values { |map| map.coercible(&coercer) })
        end

        def stringified
          new(name: name.to_s, shapes: shapes.transform_values(&:stringified))
        end

        def to_dot_notation
          shapes.flat_map { |depth, map| member_paths(map, depth) }
        end

        def dump = [name, shapes.transform_values(&:dump)]

        private

        def write_value(value, depth)
          if value.is_a?(::Hash) && (map = shapes[depth])
            map.write(value)
          elsif value.is_a?(::Array) && depth < @last_depth
            value.map { |member| write_value(member, depth + 1) }
          else
            value
          end
        end
      end
    end
  end
end
