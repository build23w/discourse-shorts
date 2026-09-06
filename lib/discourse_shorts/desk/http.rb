# frozen_string_literal: true
# v0.9.0 — one small HTTP helper for every outbound call the desk makes
# (Workers AI, source pages, RSS, shirtlab.lol, Discord, IndexNow). Browser-shaped
# User-Agent WITHOUT the word "Chrome" (the forum's own Cloudflare rule challenges
# HTTP/1.1 + "Chrome"), short timeouts, a couple of retries on 429/502/503, and it
# never raises: callers get [status, body] with status 0 on a transport failure.
require "net/http"
require "json"
require "uri"

module DiscourseShorts
  module Desk
    module Http
      UA = "Mozilla/5.0 (compatible; HRR-Desk/1.0; +https://home.renovation.reviews)"
      MAX_BODY = 1_500_000

      def self.request(url, method: :get, body: nil, headers: {}, timeout: 30, retries: 2, redirects: 3)
        uri = URI(url)
        (retries + 1).times do |attempt|
          begin
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            http.open_timeout = 12
            http.read_timeout = timeout
            klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, delete: Net::HTTP::Delete }[method] || Net::HTTP::Get
            req = klass.new(uri.request_uri, { "User-Agent" => UA, "Accept" => "*/*" }.merge(headers))
            req.body = body || (%i[post put].include?(method) ? "" : nil)
            res = http.request(req)
            code = res.code.to_i
            if [301, 302, 303, 307, 308].include?(code) && res["location"] && redirects > 0 && method == :get
              loc = URI.join(url, res["location"]).to_s
              return request(loc, method: :get, headers: headers, timeout: timeout, retries: 0, redirects: redirects - 1)
            end
            if [429, 502, 503].include?(code) && attempt < retries
              sleep(4 * (attempt + 1))
              next
            end
            return [code, res.body.to_s[0, MAX_BODY].dup.force_encoding("UTF-8").scrub("")]
          rescue StandardError => e
            Rails.logger.warn("[hrr-desk] http #{method} #{uri.host} failed: #{e.class} #{e.message}") if attempt == retries
            sleep(2) if attempt < retries
          end
        end
        [0, ""]
      end

      def self.get(url, headers: {}, timeout: 30)
        request(url, headers: headers, timeout: timeout)
      end

      def self.get_json(url, headers: {}, timeout: 30)
        code, raw = request(url, headers: { "Accept" => "application/json" }.merge(headers), timeout: timeout)
        return nil unless code == 200
        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      def self.post_json(url, payload, headers: {}, timeout: 30, retries: 1)
        code, raw = request(url, method: :post, body: payload.to_json,
                            headers: { "Content-Type" => "application/json", "Accept" => "application/json" }.merge(headers),
                            timeout: timeout, retries: retries)
        parsed = (JSON.parse(raw) rescue nil)
        [code, parsed]
      end

      # HTML -> readable text. Drops script/style/nav/header/footer blocks first.
      def self.text_of(html)
        s = html.to_s.dup
        s = s.gsub(%r{<(script|style|noscript|svg|nav|header|footer|iframe|form)\b[^>]*>.*?</\1>}im, " ")
        s = s.gsub(/<br\s*\/?>|<\/p>|<\/li>|<\/h[1-6]>|<\/tr>/i, "\n")
        s = s.gsub(/<[^>]+>/, " ")
        s = CGI.unescapeHTML(s)
        s = s.gsub(/[ \t ]+/, " ").gsub(/\s*\n\s*/, "\n").gsub(/\n{2,}/, "\n")
        s.strip
      end
    end
  end
end
