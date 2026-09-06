# frozen_string_literal: true
# v0.9.0 — the HRR desk's model client. Talks to Cloudflare Workers AI over REST
# (the same Llama models the LF Builders CRM brain runs on) with the account id
# and an API token from site settings. Nothing here posts anything; it only
# returns text, keeps a daily call budget in PluginStore, and never raises past
# its own boundary — a failed model call is a skipped job, not a broken forum.
require "net/http"
require "json"

module DiscourseShorts
  module Desk
    module Ai
      STORE = "discourse-shorts-desk"
      UA = "Mozilla/5.0 (compatible; HRR-Desk/1.0; +https://home.renovation.reviews)"

      def self.enabled?
        SiteSetting.hrr_desk_enabled && SiteSetting.hrr_desk_ai_token.to_s.strip.present? &&
          SiteSetting.hrr_desk_ai_account.to_s.strip.present?
      end

      def self.budget_key
        "ai-calls-#{Time.now.utc.strftime('%Y-%m-%d')}"
      end

      def self.calls_today
        PluginStore.get(STORE, budget_key).to_i
      end

      def self.spend!
        n = calls_today + 1
        PluginStore.set(STORE, budget_key, n)
        n
      end

      def self.over_budget?
        calls_today >= SiteSetting.hrr_desk_max_ai_calls_per_day.to_i
      end

      # Returns the model's text, or nil. `json: true` asks for and extracts a JSON object.
      def self.chat(system:, user:, max_tokens: 900, json: false, temperature: 0.4)
        return nil unless enabled?
        if over_budget?
          Rails.logger.warn("[hrr-desk] AI budget exhausted for today")
          return nil
        end
        spend!
        model = SiteSetting.hrr_desk_ai_model.to_s.strip.presence || "@cf/meta/llama-3.3-70b-instruct-fp8-fast"
        uri = URI("https://api.cloudflare.com/client/v4/accounts/#{SiteSetting.hrr_desk_ai_account.to_s.strip}/ai/run/#{model}")
        body = { messages: [{ role: "system", content: system }, { role: "user", content: user }],
                 max_tokens: max_tokens, temperature: temperature }
        body[:response_format] = { type: "json_object" } if json
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 15
        http.read_timeout = 120
        req = Net::HTTP::Post.new(uri.path, { "Authorization" => "Bearer #{SiteSetting.hrr_desk_ai_token.to_s.strip}",
                                              "Content-Type" => "application/json", "User-Agent" => UA })
        req.body = body.to_json
        res = http.request(req)
        if res.code.to_i != 200 && json && body[:response_format]
          # some models reject response_format; ask again for plain text and parse it ourselves
          body.delete(:response_format)
          req.body = body.to_json
          res = http.request(req)
        end
        unless res.code.to_i == 200
          Rails.logger.warn("[hrr-desk] AI HTTP #{res.code}: #{res.body.to_s[0, 200]}")
          return nil
        end
        data = JSON.parse(res.body) rescue nil
        result = data && data["result"]
        text = result.is_a?(Hash) ? (result["response"] || result["result"] || result.dig("choices", 0, "message", "content")) : result
        text = text.to_s.strip
        return nil if text.blank?
        json ? extract_json(text) : text
      rescue StandardError => e
        Rails.logger.warn("[hrr-desk] AI call failed: #{e.class} #{e.message}")
        nil
      end

      def self.extract_json(text)
        s = text.to_s.gsub(/\A```(?:json)?\s*/i, "").gsub(/```\s*\z/, "").strip
        start = s.index("{")
        return nil unless start
        depth = 0
        (start...s.length).each do |i|
          c = s[i]
          depth += 1 if c == "{"
          depth -= 1 if c == "}"
          if depth == 0
            return JSON.parse(s[start..i]) rescue nil
          end
        end
        nil
      end
    end
  end
end
