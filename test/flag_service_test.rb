# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/flag_service"
require "net/http"
require "json"

class FlagServiceTest < Minitest::Test
  def setup
    @service = FlagService.new.start
  end

  def teardown
    @service.stop
  end

  def test_serves_canned_json_and_records_request_headers
    @service.respond_with(status: 200, body: {"Flags" => {}}.to_json,
      headers: {"ETag" => '"1"', "Content-Type" => "application/json"})
    uri = URI(@service.url)
    res = Net::HTTP.start(uri.host, uri.port) do |http|
      http.get(uri.path, {"If-None-Match" => '"0"', "Accept" => "application/json"})
    end
    assert_equal "200", res.code
    assert_equal '"1"', res["etag"]
    assert_equal '"0"', @service.requests.last.headers["if-none-match"]
  end

  def test_programmable_block_and_status_304
    @service.respond { |req| [304, {}, nil] }
    uri = URI(@service.url)
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.get(uri.path) }
    assert_equal "304", res.code
  end
end
