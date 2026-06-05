# frozen_string_literal: true
require "net/http"
require "uri"
require "json"

module DiscourseShorts
  module Youtube
    ID = /\A[A-Za-z0-9_-]{11}\z/

    def self.extract_id(input)
      s = input.to_s.strip
      return s if s =~ ID
      [%r{youtu\.be/([A-Za-z0-9_-]{11})}, %r{/shorts/([A-Za-z0-9_-]{11})},
       %r{[?&]v=([A-Za-z0-9_-]{11})}, %r{/embed/([A-Za-z0-9_-]{11})}].each do |re|
        m = s.match(re)
        return m[1] if m
      end
      nil
    end

    # Returns parsed oEmbed hash if the video exists AND is embeddable, else nil.
    def self.oembed(video_id)
      uri = URI("https://www.youtube.com/oembed?url=https://youtu.be/#{video_id}&format=json")
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 7) { |h| h.get(uri.request_uri) }
      return nil unless res.is_a?(Net::HTTPSuccess)
      JSON.parse(res.body)
    rescue StandardError
      nil
    end

    # YouTube Data API v3 search for SHORT videos. Returns array of video ids.
    def self.search(term, max: 10)
      key = SiteSetting.shorts_youtube_api_key.to_s
      return [] if key.blank?
      uri = URI("https://www.googleapis.com/youtube/v3/search")
      uri.query = URI.encode_www_form(
        part: "snippet", q: term, type: "video", videoDuration: "short",
        videoEmbeddable: "true", maxResults: [[max.to_i, 1].max, 50].min,
        safeSearch: "moderate", relevanceLanguage: "en", key: key
      )
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 8) { |h| h.get(uri.request_uri) }
      return [] unless res.is_a?(Net::HTTPSuccess)
      (JSON.parse(res.body)["items"] || []).map { |i| i.dig("id", "videoId") }.compact
    rescue StandardError
      []
    end
  end
end
