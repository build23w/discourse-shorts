# frozen_string_literal: true

module DiscourseShorts
  # v0.5.0 — Per-user shorts recommender. Ranks the SHARED candidate pool for
  # each signed-in user using four signal families, then Journey phases on
  # top. Designed for thousands of concurrent viewers:
  #   pool        = 1 cached query / 60s (shared)
  #   profile     = 1 cached build / 5 min / user (3-4 indexed lookups)
  #   rank        = in-memory stable sort over <=400 hashes (sub-ms)
  #
  # Signals:
  #   TAG AFFINITY — tags of shorts this user liked (+) / disliked (−)
  #   LEARNED      — v0.5.0: the latest-geo client model's synced interest
  #                  profile (via ::RrGeo::SignalHub). Forum reading habits now
  #                  shape the shorts rail; shorts engagement already trains
  #                  the forum feed (rr-shorts-engage) — the loop is closed.
  #   GEO          — tokens from the user's profile location vs short title+tags
  #                  (v0.5.0: sourced from SignalHub — stopword-filtered,
  #                  comma-segment phrases — with the old splitter as fallback)
  #   SOCIAL       — shorts submitted by creators the user follows (coin-engine
  #                  social graph via SignalHub), the strongest single signal
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
      ::Discourse.cache.fetch("shorts_reco_profile_v2_#{user.id}", expires_in: PROFILE_TTL) do
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
        learned = learned_tags(user)
        { up: up, down: down, geo: geo, followed: followed, learned: learned,
          empty: up.empty? && down.empty? && geo.empty? && followed.empty? && learned.empty? }
      end
    end

    # v0.5.0: forum-learned interests (latest-geo client model, synced server-
    # side as a weighted tag profile). Hub-guarded: empty when latest-geo is
    # absent or the user has no synced profile yet.
    def self.learned_tags(user)
      return {} unless defined?(::RrGeo::SignalHub)
      out = {}
      (::RrGeo::SignalHub.interest_profile(user)[:tags] || []).each do |name, w|
        n = name.to_s.downcase.strip
        out[n] = w.to_f.clamp(0.0, 1.0) unless n.empty?
      end
      out
    rescue StandardError
      {}
    end

    def self.geo_tokens(user)
      # v0.5.0: prefer the hub's tokenizer (comma-segment phrases, geo
      # stopwords removed) so shorts and the topic feed agree on what "local"
      # means; the old splitter remains as fallback.
      if defined?(::RrGeo::SignalHub)
        toks = ::RrGeo::SignalHub.geo_tokens(user)
        return toks.first(12) if toks.present?
      end
      loc = user.user_profile&.location.to_s.downcase
      return [] if loc.empty?
      toks = loc.split(/[,\/\s]+/).map(&:strip).reject { |t| t.length < 3 }
      (toks + toks.map { |t| t.tr(' ', '-') }).uniq.first(8)
    rescue StandardError
      []
    end

    def self.followed_ids(user)
      if defined?(::RrGeo::SignalHub)
        ids = ::RrGeo::SignalHub.followed_ids(user)
        return ids if ids.present?
      end
      return [] unless defined?(::DiscourseCoinEngine::Follow)
      ::DiscourseCoinEngine::Follow.where(follower_id: user.id).limit(500).pluck(:following_id)
    rescue StandardError
      []
    end

    def self.score(h, prof)
      sc = 0.0
      learned = prof[:learned] || {}
      tags = (h[:tags] || []).map { |t| t.to_s.downcase }
      tags.each do |t|
        sc += 1.2 * [prof[:up][t], 5].min / 5.0
        sc -= 1.5 * [prof[:down][t], 5].min / 5.0
        # v0.5.0: forum-learned interest — weaker than a direct shorts
        # reaction (the user said it about THREADS), stronger than nothing.
        sc += 0.9 * learned[t].to_f if learned[t]
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
