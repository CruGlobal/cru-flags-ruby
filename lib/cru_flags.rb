# frozen_string_literal: true

require_relative "cru_flags/version"
require_relative "cru_flags/errors"
require_relative "cru_flags/document"
require_relative "cru_flags/fetcher"
require_relative "cru_flags/client"

# Module-level singleton — the 99% path (design doc §3.1). Requiring this
# file does nothing: no env read, no socket, no thread.
module CruFlags
  ENV_VAR = "CRU_FLAGS_URL"

  @client_mutex = Mutex.new
  @client = nil
  @flipper_adapter_mutex = Mutex.new
  @flipper_adapter = nil
  @fallback_store = nil
  @fallback_store_set = false
  @default_fallback_store = nil

  class << self
    # The singleton's cross-process fallback store (design doc §6.1). Any
    # assignment, nil included, beats default_fallback_store (the Railtie's
    # Rails.cache) whenever it happens: the singleton resolves the store on
    # every use, not once at construction.
    attr_writer :default_fallback_store

    def fallback_store=(store)
      @fallback_store_set = true
      @fallback_store = store
    end

    def fallback_store
      @fallback_store_set ? @fallback_store : @default_fallback_store&.call
    end

    # The env read happens inside Client (Client.url_from_env), so the
    # singleton and a hand-rolled `Client.new` share one normalization
    # rather than two copies that can drift.
    def client
      @client || @client_mutex.synchronize { @client ||= Client.new(fallback_store: -> { fallback_store }) }
    end

    def enabled?(name) = client.enabled?(name)

    def ready(timeout: nil) = client.ready(timeout:)

    def snapshot = client.snapshot

    def refresh(force: false) = client.refresh(force:)

    # Nil-safe on the ivar, like reset!: going through the memoizing reader
    # would BUILD (and validate) a singleton just to close it, leaving a
    # permanently-closed client memoized — and emitting the invalid-URL
    # warning at shutdown for an app that never used flags at all.
    def close = @client&.close

    # The read-only Flipper adapter (design doc §5), memoized and bound to
    # the singleton client. `flipper` is required lazily here (not at the
    # top of this file) so requiring "cru_flags" alone stays flipper-free.
    def flipper_adapter
      @flipper_adapter || @flipper_adapter_mutex.synchronize do
        @flipper_adapter ||= begin
          require_relative "cru_flags/flipper_adapter"
          FlipperAdapter.new(client)
        end
      end
    end

    # Test hook, not public API: closes and discards the singleton so the
    # next call re-reads the environment, and forgets any fallback_store
    # assignment.
    def reset!
      @client_mutex.synchronize do
        @client&.close
        @client = nil
      end
      @fallback_store_set = false
      @fallback_store = nil
      @flipper_adapter_mutex.synchronize { @flipper_adapter = nil }
    end
  end
end

require_relative "cru_flags/railtie" if defined?(Rails::Railtie)
