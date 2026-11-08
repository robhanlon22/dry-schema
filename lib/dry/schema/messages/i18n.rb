# frozen_string_literal: true

require "yaml"
require "i18n"

module Dry
  module Schema
    module Messages
      # I18n message backend
      #
      # @api public
      class I18n < Abstract
        # Translation function
        #
        # @return [Method]
        attr_reader :t

        # @api private
        def initialize
          super
          @t = ::I18n.method(:t)
        end

        # Get a message for the given key and its options
        #
        # @param [Symbol] key
        # @param [Hash] options
        #
        # @return [String]
        #
        # @api public
        def get(key, options = EMPTY_HASH)
          return unless key

          result = t.(key, locale: default_locale, **options)

          if result.is_a?(Hash)
            text = result[:text]
            meta = result.dup.tap { |h| h.delete(:text) }
          else
            text = result
            meta = EMPTY_HASH.dup
          end

          {
            text: text,
            meta: meta
          }
        end

        # Check if given key is defined
        #
        # @return [Boolean]
        #
        # @api public
        def key?(key, options)
          ::I18n.exists?(key, options.fetch(:locale, default_locale)) ||
            ::I18n.exists?(key, ::I18n.default_locale)
        end

        # Merge messages from an additional path
        #
        # @param [String, Array<String>] paths
        #
        # @return [Messages::I18n]
        #
        # @api public
        def merge(paths)
          prepare(paths)
        end

        # @api private
        def default_locale
          super || ::I18n.locale || ::I18n.default_locale
        end

        # @api private
        def prepare(paths = config.load_paths)
          paths.each do |path|
            data = ::YAML.load_file(path)

            if custom_top_namespace?(path)
              top_namespace = config.top_namespace

              mapped_data = data.transform_values { |v|
                {top_namespace => v[DEFAULT_MESSAGES_ROOT]}
              }

              store_translations(mapped_data)
            else
              store_translations(data)
            end
          end

          self
        end

        # @api private
        def interpolatable_data(_key, _options, **data)
          data
        end

        # @api private
        def interpolate(key, options, **data)
          opts = {locale: default_locale, **options, **data}
          text_key = "#{key}.text"

          if key?(text_key, opts)
            # A fallback locale can have a text subkey even when this locale has a plain string.
            # Inspect the parent before pluralizing or interpolating its metadata.
            parent_options = opts.dup
            parent_options[:count] = nil if opts[:count]
            parent_options[:deep_interpolation] = false if opts[:deep_interpolation]
            entry = t.(key, **parent_options)
            return t.(text_key, **opts) if entry.is_a?(::Hash) && entry.key?(:text)
            return entry if parent_options == opts && entry.is_a?(::String)
          end

          result = t.(key, **opts)
          result.is_a?(::Hash) ? result[:text] : result
        end

        private

        # @api private
        def store_translations(data)
          locales = data.keys.map(&:to_sym)

          ::I18n.available_locales |= locales

          locales.each do |locale|
            ::I18n.backend.store_translations(locale, data[locale.to_s])
          end
        end
      end
    end
  end
end
