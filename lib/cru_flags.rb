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

  class << self
    def client
      @client || @client_mutex.synchronize { @client ||= Client.new(url: url_from_env) }
    end

    def enabled?(name) = client.enabled?(name)

    def ready(timeout: nil) = client.ready(timeout:)

    def snapshot = client.snapshot

    def refresh(force: false) = client.refresh(force:)

    def close = client.close

    # Test hook, not public API: closes and discards the singleton so the
    # next call re-reads the environment.
    def reset!
      @client_mutex.synchronize do
        @client&.close
        @client = nil
      end
    end

    private

    def url_from_env
      value = ENV[ENV_VAR].to_s.strip
      value.empty? ? nil : value
    end
  end
end

require_relative "cru_flags/railtie" if defined?(Rails::Railtie)
