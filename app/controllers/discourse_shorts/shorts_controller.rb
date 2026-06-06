# frozen_string_literal: true
module DiscourseShorts
  class ShortsController < ::ApplicationController
    requires_plugin ::DiscourseShorts::PLUGIN_NAME
    before_action :ensure_enabled
    before_action :ensure_logged_in, only: %i[submit react watch watch_batch comments_create]
    skip_before_action :check_xhr, only: %i[index comments_index]

    def index
      limit = params[:limit].to_i
      limit = 200 if limit <= 0 || limit > 500
      # SCALE: query + serialize + owner lookups for the whole library are identical
      # for every viewer, so cache that base ~60s. Per-user my_reaction is merged in
      # afterward with one cheap pluck -> N concurrent feed loads become 1 heavy
      # query / 60s instead of N. Gentle precedence: owned videos carry a small
      # `priority` nudge so they stay in rotation without locking the top.
      base = Discourse.cache.fetch("shorts_index_base_v2_#{limit}", expires_in: 60.seconds) do
        rows = Short.where(status: "approved")
                    .order(Arel.sql("(likes - dislikes + COALESCE(priority,0)) DESC, id DESC"))
                    .limit(limit).to_a
        owners = ::User.where(id: rows.map(&:submitted_by_id).compact.uniq).index_by(&:id)
        # comment badge truth = the discussion topic's reply count (covers native
        # replies + deletions); one batched pluck per cache rebuild.
        tcounts = ::Topic.where(id: rows.map(&:topic_id).compact).pluck(:id, :posts_count).to_h
        rows.map do |s|
          h = serialize_short(s, nil, owners[s.submitted_by_id])
          h[:comment_count] = [tcounts[s.topic_id].to_i - 1, 0].max if s.topic_id && tcounts.key?(s.topic_id)
          h
        end
      end
      if current_user && base.any?
        mine = Reaction.where(user_id: current_user.id, short_id: base.map { |h| h[:id] })
                       .pluck(:short_id, :direction).to_h
        base = base.map { |h| (d = mine[h[:id]]) ? h.merge(my_reaction: d) : h } if mine.any?
      else
        # Anon payload is identical for everyone: let browsers/CDN cache it.
        response.headers["Cache-Control"] = "public, max-age=60"
      end
      render json: { shorts: base }
    end

    def submit
      raise Discourse::InvalidAccess unless user_can_submit?(current_user)
      vid = Youtube.extract_id(params[:url].presence || params[:video_id])
      raise Discourse::InvalidParameters.new(:url) if vid.blank?
      meta = Youtube.oembed(vid)
      raise Discourse::InvalidParameters.new(:url) if meta.nil?

      if (existing = Short.find_by(video_id: vid))
        return render(json: { ok: true, duplicate: true, short: serialize_short(existing) })
      end

      auto = current_user.staff? || current_user.trust_level >= SiteSetting.shorts_auto_approve_trust_level.to_i
      s = Short.create!(
        video_id: vid, provider: "youtube",
        title: (params[:title].presence || meta["title"]).to_s[0, 160],
        tags: Array(params[:tags]).join(",")[0, 255],
        submitted_by_id: current_user.id,
        status: auto ? "approved" : "pending",
        source: "submission"
      )
      render json: { ok: true, status: s.status, short: serialize_short(s, nil, current_user) }
    end

    def react
      RateLimiter.new(current_user, "shorts_react", 60, 1.hour).performed!
      s = Short.find_by(id: params[:id]) or raise Discourse::NotFound
      dir = params[:dir].to_s
      r = Reaction.find_or_initialize_by(short_id: s.id, user_id: current_user.id)
      was = r.direction
      Short.transaction do
        case was
        when "up" then s.likes = [s.likes - 1, 0].max
        when "down" then s.dislikes = [s.dislikes - 1, 0].max
        end
        case dir
        when "up" then s.likes += 1; r.direction = "up"
        when "down" then s.dislikes += 1; r.direction = "down"
        else r.direction = nil
        end
        s.save!
        r.direction.nil? ? (r.destroy if r.persisted?) : r.save!
      end

      if dir == "up" && was != "up"
        begin
          reward_author_for_like(s, r)
        rescue StandardError => e
          Rails.logger.warn("[discourse-shorts] like reward failed: #{e.class} #{e.message}")
        end
      end

      render json: { ok: true, likes: s.likes, dislikes: s.dislikes, my: r.direction }
    rescue RateLimiter::LimitExceeded => e
      render json: { ok: false, error: "Slow down -- try again in #{e.available_in}s." }, status: 429
    end

    def watch
      s = Short.find_by(id: params[:id]) or raise Discourse::NotFound
      secs = params[:seconds].to_i
      secs = 0 if secs.negative? || secs > 3600
      Short.where(id: s.id).update_all(["views = views + 1, watch_seconds = watch_seconds + ?", secs])
      render json: { ok: true }
    end

    # POST /shorts/watch_batch.json { items: [{id:, s:}, ...] }
    # SCALE: one request per ~8 watched shorts instead of one per view — kills
    # the highest-volume write path's per-request overhead. Aggregates dupes.
    def watch_batch
      RateLimiter.new(current_user, "shorts_watch_batch", 120, 1.hour).performed!
      raw = params[:items]
      raw = (JSON.parse(raw) rescue []) if raw.is_a?(String)
      raw = [] unless raw.is_a?(Array) || raw.is_a?(ActionController::Parameters)
      agg = {}
      Array(raw).first(50).each do |it|
        h = it.respond_to?(:to_unsafe_h) ? it.to_unsafe_h : it
        next unless h.is_a?(Hash)
        id = h["id"].to_i
        next if id <= 0
        secs = h["s"].to_i
        secs = 0 if secs.negative? || secs > 3600
        a = agg[id] ||= { v: 0, s: 0 }
        a[:v] += 1
        a[:s] += secs
      end
      agg.each do |id, a|
        Short.where(id: id).update_all(["views = views + ?, watch_seconds = watch_seconds + ?", a[:v], a[:s]])
      end
      render json: { ok: true, n: agg.size }
    rescue RateLimiter::LimitExceeded
      render json: { ok: false }, status: 429
    end

    # POST /shorts/:id/share -- counts a share so the short is kept (any
    # interaction makes it permanent). No login required (anon can share).
    def share
      # Anonymous shares allowed, but throttled per-IP: shares make a short
      # permanent in the recycler, so an unthrottled endpoint = trivial abuse.
      RateLimiter.new(nil, "shorts_share_#{request.remote_ip}", 20, 1.hour).performed!
      s = Short.find_by(id: params[:id]) or raise Discourse::NotFound
      Short.where(id: s.id).update_all("shares = COALESCE(shares,0) + 1")
      render json: { ok: true }
    rescue RateLimiter::LimitExceeded
      render json: { ok: false }, status: 429
    end

    # GET /shorts/:id/comments.json
    def comments_index
      raise Discourse::NotFound unless SiteSetting.shorts_comments_enabled
      s = Short.find_by(id: params[:id]) or raise Discourse::NotFound
      limit = params[:limit].to_i
      limit = 20 if limit <= 0 || limit > 50
      render json: Discussions.list(s, limit)
    end

    # POST /shorts/:id/comments.json { raw }
    def comments_create
      raise Discourse::NotFound unless SiteSetting.shorts_comments_enabled
      s = Short.find_by(id: params[:id]) or raise Discourse::NotFound
      raw = params[:raw].to_s.strip
      raise Discourse::InvalidParameters.new(:raw) if raw.length < 2
      return render(json: { ok: false, error: "Comments are capped at 2000 characters." }, status: 422) if raw.length > 2000
      RateLimiter.new(current_user, "shorts_comment", 12, 1.hour).performed!
      result = Discussions.add_comment(s, current_user, raw)
      raise Discourse::InvalidParameters.new(:raw) if result.nil?
      return render(json: { ok: false, error: result[:error] }, status: 422) if result[:error]
      render json: { ok: true, comment: result, topic_id: s.reload.topic_id }
    rescue RateLimiter::LimitExceeded => e
      render json: { ok: false, error: "Slow down -- try again in #{e.available_in}s." }, status: 429
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.shorts_enabled
    end

    def user_can_submit?(user)
      return true if user.staff?
      return false unless SiteSetting.shorts_allow_member_submissions
      user.trust_level >= SiteSetting.shorts_min_submit_trust_level.to_i
    end

    # --- $RENO payout (mirrors PostVotesController reward rules) -----------------
    def reward_author_for_like(short, reaction)
      return unless SiteSetting.shorts_reward_enabled
      amt = SiteSetting.shorts_like_reward_amount.to_i
      return if amt <= 0
      author_id = short.submitted_by_id.to_i
      return if author_id <= 0 || author_id == current_user.id
      return if short.source == "owned"
      author = ::User.find_by(id: author_id)
      return if author.nil? || author.staff?
      return if current_user.trust_level.to_i < SiteSetting.shorts_reward_min_trust_level.to_i
      return unless defined?(::DiscourseCoinEngine) && ::DiscourseCoinEngine.respond_to?(:credit_score)

      cap_short  = SiteSetting.shorts_reward_daily_cap_per_short.to_i
      cap_author = SiteSetting.shorts_reward_daily_cap_per_author.to_i
      since = Time.zone.now.beginning_of_day
      short_paid  = Reaction.where(short_id: short.id, rewarded: true).where("updated_at >= ?", since).count * amt
      author_paid = Reaction.joins("INNER JOIN discourse_shorts ds ON ds.id = discourse_shorts_reactions.short_id")
                            .where("ds.submitted_by_id = ?", author_id)
                            .where(rewarded: true).where("discourse_shorts_reactions.updated_at >= ?", since).count * amt
      return unless (short_paid + amt <= cap_short) && (author_paid + amt <= cap_author)

      reaction.update_column(:rewarded, true)
      ::DiscourseCoinEngine.credit_score(author_id, Date.today, amt)
      ::DiscourseCoinEngine.refresh_user_score(author_id) if ::DiscourseCoinEngine.respond_to?(:refresh_user_score)
      coin = (SiteSetting.coin_engine_coin_name rescue "$RENO")
      MessageBus.publish("/coin-engine/credits/#{author_id}", {
        amount: amt, reason: "short_like_reward",
        label: "+#{amt} #{coin} -- your short was liked",
        coin: coin, ref: { kind: "short_like", short_id: short.id }, ts: Time.now.to_i
      }, user_ids: [author_id])
    end

    def serialize_short(s, my = nil, owner = nil)
      owner ||= (s.submitted_by_id ? ::User.find_by(id: s.submitted_by_id) : nil)
      {
        id: s.id, video_id: s.video_id, provider: s.provider,
        video_url: s.video_url, upload_ref: s.upload_ref, poster_url: s.poster_url,
        title: s.title, tags: s.tag_list,
        likes: s.likes, dislikes: s.dislikes, views: s.views, shares: s.try(:shares).to_i, my_reaction: my,
        source: s.source, owned: s.source == "owned", priority: s.priority.to_i,
        comment_count: s.comment_count.to_i,
        topic_id: s.topic_id,
        owner: owner ? {
          id: owner.id, username: owner.username, name: owner.name,
          avatar_template: owner.avatar_template, path: "/u/#{owner.username}"
        } : nil
      }
    end
  end
end
