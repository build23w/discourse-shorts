# frozen_string_literal: true
module DiscourseShorts
  class ShortsController < ::ApplicationController
    requires_plugin ::DiscourseShorts::PLUGIN_NAME
    before_action :ensure_enabled
    before_action :ensure_logged_in, only: %i[submit react watch watch_batch comments_create]
    skip_before_action :check_xhr, only: %i[index comments_index share_page]
    skip_before_action :redirect_to_login_if_required, only: %i[share_page], raise: false

    def index
      limit = params[:limit].to_i
      limit = 200 if limit <= 0 || limit > 500
      # SCALE: query + serialize + owner lookups for the whole library are identical
      # for every viewer, so cache that base ~60s. Per-user my_reaction is merged in
      # afterward with one cheap pluck -> N concurrent feed loads become 1 heavy
      # query / 60s instead of N. Gentle precedence: owned videos carry a small
      # `priority` nudge so they stay in rotation without locking the top.
      # LINEUP v2 (2026-06-06): pure cumulative-likes ordering froze the lineup —
      # early winners sat on top forever, new shorts entered buried at ~#400,
      # never got seen, never earned the engagement that saves them from the
      # recycler. Now three terms beyond engagement:
      #   fresh boost (+6 for 72h)   — new arrivals surface near the top
      #   rotation jitter (0..8)     — deterministic per-6h-bucket shuffle so the
      #                                lineup reshuffles 4x/day (stable within a
      #                                bucket = stable for the 60s cache + SWR)
      # Engagement still matters; it just can't fossilize the order anymore.
      bucket = Time.zone.now.to_i / 21_600
      # v0.5.0: Media.cache_token in the key — flipping cloudflared mode (or its
      # base URL) must not serve the other mode's media URLs for a cache TTL.
      base = Discourse.cache.fetch("shorts_index_base_v4_#{limit}_#{bucket}_#{Media.cache_token}", expires_in: 60.seconds) do
        order_sql = "(likes - dislikes + COALESCE(priority,0) " \
                    "+ CASE WHEN created_at > NOW() - INTERVAL '72 hours' THEN 6 ELSE 0 END " \
                    "+ (((id::bigint * #{bucket}) % 97) / 97.0 * 8)) DESC, id DESC"
        rows = Short.where(status: "approved")
                    .order(Arel.sql(order_sql))
                    .limit(limit).to_a
        # v0.3.3: engagement-ranked order let established shorts squat the top
        # forever — weave the newest arrivals (7 days) into every 4th slot of
        # the top of the lineup so fresh ingests are actually SEEN.
        begin
          fresh_ids = Short.where(status: "approved").where("created_at > ?", 7.days.ago)
                           .order(id: :desc).limit(12).pluck(:id)
          if fresh_ids.any?
            fresh_rows, rest = rows.partition { |s| fresh_ids.include?(s.id) }
            woven = []
            fi = 0
            ri = 0
            idx = 0
            while ri < rest.length || fi < fresh_rows.length
              if fi < fresh_rows.length && idx % 4 == 3 && idx < 48
                woven << fresh_rows[fi]; fi += 1
              elsif ri < rest.length
                woven << rest[ri]; ri += 1
              else
                woven << fresh_rows[fi]; fi += 1
              end
              idx += 1
            end
            rows = woven
          end
        rescue StandardError
          nil
        end
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
      # v0.4.0 explicit category filter (chips). Applied per-request to the
      # shared cached base so the base cache stays viewer-agnostic.
      cat_counts = base.each_with_object(Hash.new(0)) { |h, m| (m[h[:category]] += 1) if h[:category] }
      sel_cat = params[:category].to_s.strip
      base = base.select { |h| h[:category].to_s == sel_cat } if sel_cat.present? && sel_cat != "all"
      journey = nil
      if current_user && base.any?
        mine = Reaction.where(user_id: current_user.id, short_id: base.map { |h| h[:id] })
                       .pluck(:short_id, :direction).to_h
        base = base.map { |h| (d = mine[h[:id]]) ? h.merge(my_reaction: d) : h } if mine.any?
        # PER-USER RECOMMENDER: tag affinity + geo + followed creators rank the
        # shared pool for THIS user (cached profile, in-memory sort) before the
        # journey phases curate on top. 5000 concurrent users = 5000 cheap
        # in-memory sorts over one shared pool query.
        if SiteSetting.shorts_recommender_enabled
          base = Recommender.rank(base, current_user)
        end
        # The lovely learning engine: re-order the rail per learner (love ->
        # growth -> discovery) and attach warm journey microcopy. Pure Ruby
        # over the cached base + two indexed lookups; falls back to the
        # global order on any error.
        if SiteSetting.shorts_journey_enabled
          begin
            state = Journey.learner_state(current_user, base)
            base, journey = Journey.curate(base, state, current_user.id)
          rescue StandardError => e
            Rails.logger.warn("[discourse-shorts] journey fell back: #{e.class} #{e.message}")
          end
        end
      else
        # Anon payload is identical for everyone: let browsers/CDN cache it.
        # Anons still get a (static) journey line — the lovely-learning rail
        # should greet logged-out visitors too, at zero per-user cost.
        if SiteSetting.shorts_journey_enabled
          journey = {
            completed: 0,
            areas_explored: 0,
            areas_total: Journey::AREAS.keys.length,
            loved_areas: [],
            loved_labels: [],
            next_up: nil,
            encouragement: "Pick any short — 30 seconds is all it takes to learn your first renovation trick.",
          }
        end
        response.headers["Cache-Control"] = "public, max-age=60"
      end
      payload = { shorts: base }
      payload[:journey] = journey if journey
      payload[:categories] = cat_counts.map { |k, n| { key: k, label: (Journey::AREA_LABELS[k] || k.to_s.tr("-", " ").capitalize), count: n } }.sort_by { |c| -c[:count] }
      render json: payload
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
        description: params[:description].to_s.strip[0, 600].presence,
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
      record_progress(current_user.id, s.id, secs)
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
        record_progress(current_user.id, id, a[:s], a[:v])
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
      ip = (request.get_header("HTTP_CF_CONNECTING_IP").presence || request.remote_ip)  # CF edge ip rotates; use true client
      RateLimiter.new(nil, "shorts_share_#{ip}", 20, 1.hour).performed!
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

    # GET /shorts/v/:video_id — server-rendered share page. Link unfurlers
    # (iMessage/WhatsApp/FB/X crawlers) don't run JS, so /?short=ID gave them
    # generic homepage metadata. This page carries the short's own OpenGraph +
    # Twitter Card tags (title, poster image, video) and instantly forwards
    # human visitors into the on-site viewer.
    def share_page
      s = Short.find_by(video_id: params[:video_id]) or raise Discourse::NotFound
      raise Discourse::NotFound unless s.status == "approved"
      base = Discourse.base_url

      # HUMANS: instant server-side 302 into the viewer. No JS (Discourse CSP is
      # script-src 'strict-dynamic' — inline scripts are blocked, so a JS hop
      # would strand users), and junk tracking params platforms append
      # (fbclid, gclid, etc.) are dropped because we construct the URL ourselves.
      # CRAWLERS (facebookexternalhit/Twitterbot/WhatsApp/...) stay on this page
      # and read the short's own OpenGraph tags.
      unless CrawlerDetection.crawler?(request.user_agent)
        return redirect_to "#{base}/?short=#{ERB::Util.url_encode(s.video_id)}&utm_source=lf_short&utm_medium=share"
      end
      title = (s.title.presence || "Renovation Short").to_s[0, 90]
      poster = Media.cdn(s.poster_url.presence) ||
               (s.provider == "youtube" ? "https://i.ytimg.com/vi/#{s.video_id}/hqdefault.jpg" : "#{base}/uploads/default/original/1X/logo.png")
      viewer = "#{base}/?short=#{ERB::Util.url_encode(s.video_id)}&utm_source=lf_short&utm_medium=share"
      self_url = "#{base}/shorts/v/#{ERB::Util.url_encode(s.video_id)}"
      desc = "Watch this renovation short and join the conversation on home.renovation.reviews"
      e = ->(x) { ERB::Util.html_escape(x.to_s) }
      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <title>#{e.call(title)} — Renovation Shorts</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="canonical" href="#{e.call(self_url)}">
        <meta property="og:type" content="video.other">
        <meta property="og:site_name" content="Home Renovation Reviews">
        <meta property="og:title" content="#{e.call(title)}">
        <meta property="og:description" content="#{e.call(desc)}">
        <meta property="og:image" content="#{e.call(poster)}">
        <meta property="og:url" content="#{e.call(self_url)}">
        #{s.provider == "youtube" ? %(<meta property="og:video" content="https://www.youtube.com/embed/#{e.call(s.video_id)}">
<meta property="og:video:type" content="text/html">
<meta property="og:video:width" content="720">
<meta property="og:video:height" content="1280">) : ""}
        <meta name="twitter:card" content="summary_large_image">
        <meta name="twitter:title" content="#{e.call(title)}">
        <meta name="twitter:description" content="#{e.call(desc)}">
        <meta name="twitter:image" content="#{e.call(poster)}">
        <style>
          body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;background:#0f1624;color:#fff;font-family:system-ui,Segoe UI,Arial,sans-serif}
          .sp{width:42px;height:42px;border-radius:50%;border:4px solid rgba(255,255,255,.25);border-top-color:#f0820c;animation:r 0.9s linear infinite}
          @keyframes r{to{transform:rotate(360deg)}}
          a{color:#f0820c;font-weight:600;text-decoration:none}
        </style>
        </head><body>
        <div class="sp" role="status" aria-label="Loading"></div>
        <p>Opening “#{e.call(title)}”…</p>
        <p><a href="#{e.call(viewer)}">Tap here if nothing happens</a></p>
        </body></html>
      HTML
      response.headers["Cache-Control"] = "public, max-age=300"
      response.headers["Vary"] = "User-Agent"   # response differs for crawlers vs humans
      render html: html.html_safe, content_type: "text/html", layout: false
    end

    private

    # Per-user watch attribution — the learner's memory. Completion flips at
    # shorts_complete_seconds of cumulative watch time and never unflips.
    def record_progress(user_id, short_id, secs, watches = 1)
      return if user_id.to_i <= 0
      row = Progress.find_or_initialize_by(user_id: user_id, short_id: short_id)
      was_completed = !!row.completed
      row.seconds = row.seconds.to_i + secs.to_i
      row.watches = row.watches.to_i + watches.to_i
      row.completed ||= row.seconds >= [SiteSetting.shorts_complete_seconds.to_i, 5].max
      row.save!
      if row.completed && !was_completed
        # journey counters changed -> bust the 5-min per-user cache so the
        # "X/N skills - Y lessons" widget reflects the new lesson promptly.
        (::Discourse.cache.delete("shorts_journey_state_v1_#{user_id}") rescue nil)
        reward_learner_for_lesson(user_id, short_id, row)
      end
    rescue StandardError => e
      Rails.logger.warn("[discourse-shorts] progress write failed: #{e.class} #{e.message}")
    end

    # v0.4.0 LEARN-AND-EARN: grant $RENO the instant a learner COMPLETES a short
    # (first completion only, tracked via rewarded_at), capped at
    # shorts_lesson_daily_cap rewarded lessons/day. This is the daily mechanic:
    # log in, finish up to N lessons, earn each day. Reward goes to the LEARNER.
    def reward_learner_for_lesson(user_id, short_id, row)
      return unless SiteSetting.shorts_reward_enabled
      amt = SiteSetting.shorts_lesson_reward_amount.to_i
      return if amt <= 0
      return if row.respond_to?(:rewarded_at) && row.rewarded_at.present?  # once per short, ever
      learner = ::User.find_by(id: user_id)
      return if learner.nil? || learner.bot?
      return if learner.trust_level.to_i < SiteSetting.shorts_reward_min_trust_level.to_i
      return unless defined?(::DiscourseCoinEngine) && ::DiscourseCoinEngine.respond_to?(:credit_score)
      cap = SiteSetting.shorts_lesson_daily_cap.to_i
      if cap.positive?
        since = Time.zone.now.beginning_of_day
        rewarded_today = Progress.where(user_id: user_id).where("rewarded_at >= ?", since).count
        return if rewarded_today >= cap
      end
      row.update_column(:rewarded_at, Time.zone.now)   # claim BEFORE crediting (race-safe, no double pay)
      ::DiscourseCoinEngine.credit_score(user_id, Date.today, amt)
      ::DiscourseCoinEngine.refresh_user_score(user_id) if ::DiscourseCoinEngine.respond_to?(:refresh_user_score)
      coin = (SiteSetting.coin_engine_coin_name rescue "$RENO")
      MessageBus.publish("/coin-engine/credits/#{user_id}", {
        amount: amt, reason: "lesson_reward",
        label: "+#{amt} #{coin} -- lesson complete!",
        coin: coin, ref: { kind: "lesson", short_id: short_id }, ts: Time.now.to_i
      }, user_ids: [user_id])
    rescue StandardError => e
      Rails.logger.warn("[discourse-shorts] lesson reward failed: #{e.class} #{e.message}")
    end

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
      cat = s.try(:category).presence || (Journey.classify(title: s.title.to_s, tags: Array(s.tag_list)).first rescue "general")
      # CLOUDFLARED MODE (v0.5.0): media URLs go out CDN-remapped; when a remap
      # happened the original store URL ships as *_origin so the player can
      # fall back if the edge object 404s (e.g. creator-upload mirror in flight).
      v_cdn, v_origin = Media.cdn_pair(s.video_url)
      vp9_cdn, vp9_origin = Media.cdn_pair(s.try(:vp9_url))
      p_cdn, p_origin = Media.cdn_pair(s.poster_url)
      h = {
        id: s.id, video_id: s.video_id, provider: s.provider,
        video_url: v_cdn, vp9_url: vp9_cdn, upload_ref: s.upload_ref, poster_url: p_cdn,
        title: s.title, description: s.try(:description), tags: s.tag_list, created_at: (s.created_at.to_i rescue nil),
        category: cat, category_label: (Journey::AREA_LABELS[cat] || cat.to_s.tr("-", " ").capitalize),
        likes: s.likes, dislikes: s.dislikes, views: s.views, shares: s.try(:shares).to_i, my_reaction: my,
        source: s.source, owned: s.source == "owned", priority: s.priority.to_i,
        comment_count: s.comment_count.to_i,
        topic_id: s.topic_id,
        owner: owner ? {
          id: owner.id, username: owner.username, name: owner.name,
          avatar_template: owner.avatar_template, path: "/u/#{owner.username}"
        } : nil
      }
      h[:video_url_origin] = v_origin if v_origin
      h[:vp9_url_origin] = vp9_origin if vp9_origin
      h[:poster_url_origin] = p_origin if p_origin
      h
    end
  end
end
