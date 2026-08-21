# frozen_string_literal: true

require "net/http"
require "uri"

module CruFlags
  # One conditional GET of the flag document. Stateless; the Client owns the
  # etag and the snapshot. Never raises — every failure is an Outcome.
  module Fetcher
    Outcome = Struct.new(:kind, :document, :etag, :error)

    REDIRECT_LIMIT = 3
    REDIRECT_CODES = %w[301 302 303 307 308].freeze
    BODY_EXCERPT = 200

    module_function

    def call(url:, etag: nil, timeout: 2.0)
      response = get_following_redirects(URI(url), etag:, timeout:)
      case response.code
      when "200"
        document = Document.parse(response.body.to_s)
        Outcome.new(kind: :document, document:, etag: response["etag"])
      when "304" then Outcome.new(kind: :not_modified)
      when "404" then Outcome.new(kind: :missing)
      else
        excerpt = response.body.to_s.strip[0, BODY_EXCERPT]
        failed(FetchError.new("flag fetch failed with HTTP #{response.code}: #{excerpt}",
          code: :http, status: Integer(response.code)))
      end
    rescue FetchError => e
      failed(e)
    rescue ParseError => e
      failed(FetchError.new(e.message, code: :parse))
    rescue Timeout::Error => e
      failed(FetchError.new("flag fetch timed out: #{e.message}", code: :timeout))
    rescue SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError => e
      failed(FetchError.new("flag fetch failed: #{e.message}", code: :network))
    end

    def get_following_redirects(uri, etag:, timeout:)
      REDIRECT_LIMIT.downto(0) do |hops_left|
        response = get(uri, etag:, timeout:)
        return response unless REDIRECT_CODES.include?(response.code)
        if hops_left.zero?
          raise FetchError.new("flag fetch exceeded #{REDIRECT_LIMIT} redirects",
            code: :http, status: Integer(response.code))
        end
        uri = uri.merge(response["location"].to_s)
      end
    end

    def get(uri, etag:, timeout:)
      headers = {"Accept" => "application/json",
                 "User-Agent" => "cru-flags-ruby/#{VERSION}"}
      headers["If-None-Match"] = etag if etag
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: timeout, read_timeout: timeout, write_timeout: timeout) do |http|
        http.get(uri.request_uri, headers)
      end
    end

    def failed(error) = Outcome.new(kind: :failed, error:)
    private_class_method :get_following_redirects, :get, :failed
  end
end
