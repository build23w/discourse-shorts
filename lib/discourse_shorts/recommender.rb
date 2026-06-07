# frozen_string_literal: true

module DiscourseShorts
  # v0.4.0 — Per-user shorts recommender. Ranks the SHARED candidate pool for
  # each signed-in user using three signal families, then Journey phases on
  # top. Designed for thousands of concurrent viewers:
  #   pool        = 1 cached query / 60s (shared)
  #   profile     = 1 cached build / 5 min / user (3 indexed lookups)
  #   rank        = in-memory stable sort over <=400 hashes (sub-ms)
  #
  # Signals:
  #   TAG AFFINITY — tags of shorts this user liked (+) / disliked (−)
  #   GEO          — tokens from the user's profile location vs short title+tags
  #                  (same source latest-geo ranks the topic feed with)
  #   SOCIAL       — shorts submitted by creators the user follows (coin-engine
  #                  social graph), the strongest single signal
  module Recommender
    PROFILE_TTL = 5.minutes
    MAX_REACTIONS = 500

    def self.rank(base, user)
      prof = profile_for(user)
      return base if prof[:empty]
      base.each_with_index
          .sort_by { |h, i| [-score(h, prof), i] }   # stable: pool order tiebreaks
          .map(&:first)
    rescue StandardError => e
      Rails.logger.warn("[discourse-shorts] recommender fell back: #{e.class} #{e.message}")
      base
    end

    def self.profile_for(user)
      ::Discourse.cache.fetch("shorts_reco_profile_v1_#{user.id}", expires_in: PROFILE_TTL) do
        up = Hash.new(0)
        down = Hash.new(0)
        rows = ::ActiveRecord::Base.connection.exec_query(
          "SELECT r.direction, s.tags FROM discourse_shorts_reactions r " \
          "JOIN discourse_shorts s ON s.id = r.short_id " \
          "WHERE r.user_id = #{user.id.to_i} AND r.direction IS NOT NULL " \
          "ORDER BY r.updated_at DESC LIMIT #{MAX_REACTIONS}"
        ).to_a
        rows.each do |r|
          bucket = r['direction'] == 'up' ? up : down
          r['tags'].to_s.split(',').each { |t| t = t.strip.downcase; bucket[t] += 1 unless t.empty? }
        end
        geo = geo_tokens(user)
        followed = followed_ids(user)
        { up: up, down: down, geo: geo, followed: followed,
          empty: up.empty? && down.empty? && geo.empty? && followed.empty? }
      end
    end

    def self.geo_tokens(user)
      loc = user.user_profile&.location.to_s.downcase
      return [] if loc.empty?
      toks = loc.split(/[,\/\s]+/).map(&:strip).reject { |t| t.length < 3 }
      (toks + toks.map { |t| t.tr(' ', '-') }).uniq.first(8)
    rescue StandardError
      []
    end

    def self.followed_ids(user)
      return [] unless defined?(::DiscourseCoinEngine::Follow)
      ::DiscourseCoinEngine::Follow.where(follower_id: user.id).limit(500).pluck(:following_id)
    rescue StandardError
      []
    end

    def self.score(h, prof)
      sc = 0.0
      tags = (h[:tags] || []).map { |t| t.to_s.downcase }
      tags.each do |t|
        sc += 1.2 * [prof[:up][t], 5].min / 5.0
        sc -= 1.5 * [prof[:down][t], 5].min / 5.0
      end
      unless prof[:geo].empty?
        hay = "#{h[:title]} #{tags.join(' ')}".downcase
        prof[:geo].each { |g| (sc += 2.0; break) if hay.include?(g) }
      end
      owner_id = h[:owner] && h[:owner][:id]
      sc += 2.5 if owner_id && prof[:followed].include?(owner_id)
      sc
    end
  end
end
