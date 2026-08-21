# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "cru_flags"

class ClientCoreTest < Minitest::Test
  def setup
    @service = FlagService.new.start
    @errors = []
    @client = CruFlags::Client.new(url: @service.url, on_error: ->(e) { @errors << e })
  end

  def teardown
    @client.close
    @service.stop
  end

  def serve(body, etag: nil)
    headers = etag ? {"ETag" => etag} : {}
    @service.respond_with(status: 200, body:, headers:)
  end

  def test_enabled_is_false_before_any_fetch_and_never_raises
    refute @client.enabled?("anything")
    refute @client.enabled?(nil) # hostile input answers false, not raise
  end

  def test_refresh_publishes_document_and_enabled_reads_it
    serve('{"Flags":{"pilot":{"Enabled":true},"off":{"Enabled":false}}}', etag: '"1"')
    assert @client.refresh(force: true)
    assert @client.enabled?("pilot")
    assert @client.enabled?(:pilot) # symbols accepted
    refute @client.enabled?("off")
    refute @client.enabled?("stringly") # absent
  end

  def test_malformed_enabled_values_read_false
    serve('{"Flags":{"a":{"Enabled":"true"},"b":{"Enabled":1},"c":{"Enabled":null}}}')
    @client.refresh(force: true)
    %w[a b c].each { |name| refute @client.enabled?(name) }
  end

  def test_failure_keeps_last_known_good_indefinitely
    serve('{"Flags":{"pilot":{"Enabled":true}}}', etag: '"1"')
    @client.refresh(force: true)
    @service.respond_with(status: 500, body: "boom")
    5.times { @client.refresh(force: true) }
    assert @client.enabled?("pilot"), "outage must not turn flags off (no TTL)"
  end

  def test_health_transitions_fire_once_each_way_and_never_for_404_or_304
    serve('{"Flags":{}}', etag: '"1"')
    @client.refresh(force: true)
    @service.respond_with(status: 304)
    @client.refresh(force: true)
    @service.respond_with(status: 404)
    @client.refresh(force: true)
    assert_empty @errors
    @service.respond_with(status: 500, body: "x")
    3.times { @client.refresh(force: true) }
    assert_equal 1, @errors.size
    assert_kind_of CruFlags::FetchError, @errors.first
    serve('{"Flags":{}}')
    @client.refresh(force: true)
    assert_equal [@errors.first, nil], @errors
  end

  def test_404_publishes_empty_and_clears_etag
    serve('{"Flags":{"pilot":{"Enabled":true}}}', etag: '"7"')
    @client.refresh(force: true)
    @service.respond_with(status: 404)
    @client.refresh(force: true)
    refute @client.enabled?("pilot")
    serve('{"Flags":{}}')
    @client.refresh(force: true)
    refute_includes @service.requests.last.headers.keys, "if-none-match",
      "404 must clear the stored ETag so a reappearing document is fetched fresh"
  end

  def test_snapshot_is_a_thawed_json_roundtrippable_copy
    serve('{"Version":3,"Flags":{"pilot":{"Enabled":true}}}')
    @client.refresh(force: true)
    snap = @client.snapshot
    refute_predicate snap, :frozen?
    snap["Flags"]["pilot"]["Enabled"] = false # mutating the copy...
    assert @client.enabled?("pilot") # ...cannot touch library state
  end

  def test_refresh_without_force_is_a_noop_while_fresh
    serve('{"Flags":{}}')
    @client.refresh(force: true)
    @client.refresh
    assert_equal 1, @service.requests.size
  end

  def test_close_is_terminal
    serve('{"Flags":{"pilot":{"Enabled":true}}}')
    @client.refresh(force: true)
    @client.close
    @service.respond_with(status: 200, body: '{"Flags":{}}')
    @client.refresh(force: true)
    assert_equal 1, @service.requests.size, "closed client must not fetch"
    assert @client.enabled?("pilot"), "last snapshot stays readable"
  end

  def test_non_http_url_is_inert_with_one_warning
    client = CruFlags::Client.new(url: "file:///etc/passwd", on_error: ->(e) { @errors << e })
    assert client.inert?
    refute client.enabled?("x")
    client.close
  end

  def test_broken_on_error_handler_is_swallowed
    client = CruFlags::Client.new(url: @service.url, on_error: ->(_e) { raise "handler bug" })
    @service.respond_with(status: 500, body: "x")
    client.refresh(force: true) # must not raise
    client.close
  end
end
