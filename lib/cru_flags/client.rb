# frozen_string_literal: true

require "logger"

module CruFlags
  # The polling flag client (design doc §3–§8). One instance per process in
  # normal use, via the CruFlags module singleton.
  class Client
    VALID_SCHEMES = %w[http https].freeze

    def initialize(url: nil, poll_seconds: 30.0, fetch_timeout: 2.0,
      on_error: nil, refresh_mode: nil)
      @poll_seconds = positive(poll_seconds, 30.0)
      @fetch_timeout = positive(fetch_timeout, 2.0)
      @on_error = on_error || default_on_error
      @refresh_mode = refresh_mode # resolved in Task 7
      @url = url
      @document = nil
      @etag = nil
      @healthy = true
      @attempted = false
      @last_attempt_at = nil
      @last_attempt_ok = false
      @closed = false
      @write_mutex = Mutex.new
      validate_url!
    end

    def inert? = @url.nil?

    def enabled?(name)
      doc = @document
      doc&.dig("Flags", name.to_s, "Enabled") == true
    rescue
      false
    end

    def snapshot
      doc = @document
      doc ? JSON.parse(JSON.generate(doc)) : {}
    rescue
      {}
    end

    def refresh(force: false)
      return false if inert? || @closed
      @write_mutex.synchronize do
        attempt_fetch if force || stale?
        @attempted && @last_attempt_ok
      end
    rescue
      false
    end

    def close
      @closed = true
      nil
    end

    private

    def stale?
      @last_attempt_at.nil? ||
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_attempt_at) >= @poll_seconds
    end

    def attempt_fetch
      outcome = Fetcher.call(url: @url, etag: @etag, timeout: @fetch_timeout)
      apply(outcome)
    ensure
      @attempted = true
      @last_attempt_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def apply(outcome)
      case outcome.kind
      when :document
        @document = outcome.document # document BEFORE etag (design doc §8)
        @etag = outcome.etag
        became(healthy: true)
      when :not_modified
        became(healthy: true)
      when :missing
        @document = Document::EMPTY
        @etag = nil
        became(healthy: true)
      when :failed
        became(healthy: false, error: outcome.error)
      end
      @last_attempt_ok = outcome.kind != :failed
    end

    def became(healthy:, error: nil)
      return if healthy == @healthy
      @healthy = healthy
      report(healthy ? nil : error)
    end

    def report(error)
      @on_error.call(error)
    rescue
      nil # a broken error handler must not kill the poller
    end

    def default_on_error
      lambda do |error|
        logger = defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger ||
          (@fallback_logger ||= Logger.new($stderr, progname: "cru_flags"))
        if error
          logger.warn("cru_flags: flag fetches failing: #{error.class}: #{error.message}")
        else
          logger.warn("cru_flags: flag fetches recovered")
        end
      end
    end

    def positive(value, fallback)
      (value.is_a?(Numeric) && value.finite? && value.positive?) ? value.to_f : fallback
    end

    def validate_url!
      return if @url.nil?
      scheme = URI(@url.to_s).scheme
      unless VALID_SCHEMES.include?(scheme)
        @url = nil
        report(FetchError.new("CRU_FLAGS_URL scheme #{scheme.inspect} is not http(s); client is inert",
          code: :network))
      end
    rescue URI::InvalidURIError
      @url = nil
      report(FetchError.new("CRU_FLAGS_URL is not a valid URL; client is inert", code: :network))
    end
  end
end
