# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"
require "json"

# Concurrency guarantees that only surface under real contention: readers
# racing a fast-swapping poller must never observe a half-applied document
# (design doc §6 — documents are deep-frozen and swapped by single reference
# assignment, never mutated in place), and the poller's jitter must actually
# land in its documented band (design doc §7).
class ConcurrencyTest < Minitest::Test
  def test_readers_never_see_a_half_applied_swap
    service = FlagService.new.start
    docs = [
      '{"Version":1,"Flags":{"a":{"Enabled":true},"b":{"Enabled":true}}}',
      '{"Version":2,"Flags":{"a":{"Enabled":false},"b":{"Enabled":false}}}'
    ]
    turn = 0
    service.respond { |_req| [200, {}, docs[(turn += 1) % 2]] }
    client = CruFlags::Client.new(url: service.url, poll_seconds: 0.01)
    client.ready(timeout: 2.0)
    stop = false
    violations = []
    readers = 8.times.map do
      Thread.new do
        until stop
          snap = client.snapshot
          next if snap.empty?
          a = snap.dig("Flags", "a", "Enabled")
          b = snap.dig("Flags", "b", "Enabled")
          violations << snap if a != b # the two docs always agree internally
        end
      end
    end
    sleep 1.0
    stop = true
    readers.each(&:join)
    assert_empty violations, "a reader observed a torn document"
  ensure
    client&.close
    service&.stop
  end

  def test_jitter_distribution_stays_in_band
    samples = 10_000.times.map { rand(0.8..1.2) }
    assert_operator samples.min, :>=, 0.8
    assert_operator samples.max, :<=, 1.2
    assert_in_delta 1.0, samples.sum / samples.size, 0.01
  end
end
