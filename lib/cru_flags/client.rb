# frozen_string_literal: true

require "json"
require "logger"
require "uri"

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
      @fetch_mutex = Mutex.new
      @ready_mutex = Mutex.new
      @ready_cv = ConditionVariable.new
      @wake = Queue.new
      @thread = nil
      @pid = nil
      validate_url!
    end

    def inert? = @url.nil?

    def enabled?(name)
      ensure_started
      doc = @document
      doc&.dig("Flags", name.to_s, "Enabled") == true
    rescue
      false
    end

    def snapshot
      ensure_started
      doc = @document
      doc ? JSON.parse(JSON.generate(doc)) : {}
    rescue
      {}
    end

    # Blocks until the first fetch attempt completes (success or failure) and
    # returns whether it did within timeout. Immediately false for inert
    # clients (design doc §3.3, §7).
    def ready(timeout: nil)
      return false if inert?
      ensure_started
      return on_demand_ready if on_demand? # Task 7
      @ready_mutex.synchronize do
        deadline = timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until @attempted
          remaining = deadline && deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if remaining && remaining <= 0
          @ready_cv.wait(@ready_mutex, remaining || 1.0)
          return false if @closed && !@attempted
        end
        true
      end
    rescue
      false
    end

    def refresh(force: false)
      return false if inert? || @closed
      waited_from = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @fetch_mutex.synchronize do
        if force
          attempt_fetch unless @last_attempt_at && @last_attempt_at >= waited_from
        elsif stale?
          attempt_fetch
        end
        @attempted && @last_attempt_ok
      end
    rescue
      false
    end

    def close
      @closed = true
      @wake.push(:stop)
      @ready_mutex.synchronize { @ready_cv.broadcast }
      @thread&.join(0.1)
      nil
    end

    private

    # Task 7 introduces refresh_mode resolution; on-demand mode has no
    # poller thread at all (design doc §7.1).
    def on_demand?
      false
    end

    # Lazily arms the background poller on the first enabled?/ready/snapshot
    # call. A no-op for inert, closed, or on-demand clients. Fork-safe: a PID
    # change discards the dead parent thread's state so the child re-arms its
    # own poller on its own next read (design doc §7).
    def ensure_started
      return if inert? || @closed || on_demand?
      return if @thread && Process.pid == @pid
      @write_mutex.synchronize do
        return if @closed
        if @thread && Process.pid != @pid
          @thread = nil
          @wake = Queue.new
        end
        spawn_poller unless @thread
      end
    end

    def spawn_poller
      @pid = Process.pid
      @thread = Thread.new do
        Thread.current.name = "cru-flags-poller"
        Thread.current.report_on_exception = false
        until @closed
          attempt_fetch_coalesced(force: true)
          signal_ready
          begin
            @wake.pop(timeout: @poll_seconds * rand(0.8..1.2))
          rescue
            nil
          end
        end
      end
    end

    def attempt_fetch_coalesced(force:)
      @fetch_mutex.synchronize do
        attempt_fetch if force || stale?
      end
    end

    def signal_ready
      return unless @attempted
      @ready_mutex.synchronize { @ready_cv.broadcast }
    end

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
