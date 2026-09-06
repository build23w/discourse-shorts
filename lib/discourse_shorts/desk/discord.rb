# frozen_string_literal: true
# v0.9.0 — the forum <-> Discord bridge, ported from the three Cowork scripts of
# 2026-08-31 (feed sync, #ask-the-pros porting with consent, rank -> roles).
# Webhook URLs and the bot token live in secret site settings; nothing here
# logs them. Every Discord call goes through `api`, which honours 429 retry_after
# and returns nil on 404 instead of raising.
module DiscourseShorts
  module Desk
    module Discord
      STORE = Ai::STORE
      API = "https://discord.com/api/v10"
      BOT_UA = "HRR-Desk (https://home.renovation.reviews, 1.0)"
      PIN, WAIT, DONE, NOPE, OUT = "\u{1F4CC}", "⏳", "✅", "\u{1F6AB}", "❌"
      MANAGE_MESSAGES, ADMINISTRATOR = 1 << 13, 1 << 3
      EMBED_COLOR = 0xE8A33D

      def self.token
        SiteSetting.hrr_discord_bot_token.to_s.strip
      end

      def self.guild
        SiteSetting.hrr_discord_guild_id.to_s.strip
      end

      def self.bot?
        token.present? && guild.present?
      end

      def self.api(method, path, body = nil)
        6.times do
          code, raw = Http.request(API + path, method: method, body: body && body.to_json,
                                   headers: { "Authorization" => "Bot #{token}", "Content-Type" => "application/json", "User-Agent" => BOT_UA },
                                   timeout: 30, retries: 0)
          if code == 429
            wait = (JSON.parse(raw)["retry_after"].to_f rescue 1.0)
            sleep(wait + 0.3)
            next
          end
          return nil if code == 404
          if code >= 200 && code < 300
            return raw.blank? ? {} : (JSON.parse(raw) rescue {})
          end
          Rails.logger.warn("[hrr-desk] discord #{method} #{path} -> #{code} #{raw.to_s[0, 160]}")
          return nil
        end
        nil
      end

      # ---------- webhook feed ----------
      def self.webhook_for(category_id)
        jobs = SiteSetting.hrr_discord_job_categories.to_s.split("|").map(&:to_i)
        reviews = SiteSetting.hrr_discord_review_categories.to_s.split("|").map(&:to_i)
        if jobs.include?(category_id)
          [SiteSetting.hrr_discord_webhook_jobs.to_s.strip, "**New on the job board**"]
        elsif reviews.include?(category_id)
          [SiteSetting.hrr_discord_webhook_reviews.to_s.strip, "**New contractor review**"]
        else
          [SiteSetting.hrr_discord_webhook_new_topics.to_s.strip, "**New on the forum**"]
        end
      end

      def self.feedable?(topic)
        return false unless topic && topic.archetype == ::Archetype.default
        return false if topic.deleted_at || !topic.visible || topic.pinned_globally
        return false if topic.category&.read_restricted
        skip = SiteSetting.hrr_discord_feed_skip_categories.to_s.split("|").map(&:to_i)
        return false if skip.include?(topic.category_id)
        true
      end

      def self.embed(topic)
        n = topic.posts_count.to_i
        desc = topic.category&.name.to_s.presence || "Forum"
        desc += n <= 1 ? "" : " - #{n - 1} repl#{n == 2 ? 'y' : 'ies'}"
        { title: topic.title.to_s[0, 250], url: Forum.topic_url(topic), description: desc,
          color: EMBED_COLOR, timestamp: topic.created_at.utc.iso8601, footer: { text: URI(Forum.base_url).host } }
      end

      def self.post_webhook(url, header, embeds)
        return false if url.blank? || embeds.empty?
        payload = { embeds: embeds }
        payload[:content] = header if embeds.size > 1
        code, _ = Http.post_json(url, payload, timeout: 30, retries: 1)
        code >= 200 && code < 300
      end

      def self.watermark
        PluginStore.get(STORE, "discord-feed-last-id").to_i
      end

      def self.watermark!(id)
        PluginStore.set(STORE, "discord-feed-last-id", id) if id.to_i > watermark
      end

      # Push one topic (from the topic_created hook). Returns true when sent.
      def self.feed_topic!(topic)
        return false unless SiteSetting.hrr_discord_feed_enabled && feedable?(topic)
        url, header = webhook_for(topic.category_id)
        return false if url.blank?
        ok = post_webhook(url, header, [embed(topic)])
        watermark!(topic.id) if ok
        ok
      end

      # Hourly catch-up: anything newer than the watermark that the hook missed.
      def self.feed_catchup!
        return { skipped: "feed disabled" } unless SiteSetting.hrr_discord_feed_enabled
        last = watermark
        if last <= 0
          watermark!(::Topic.maximum(:id).to_i)
          return { initialised: true }
        end
        fresh = ::Topic.where("id > ?", last).order(:id).limit(10).to_a.select { |t| feedable?(t) }
        newest = ::Topic.where("id > ?", last).maximum(:id)
        return { sent: 0 } if fresh.empty? && newest.nil?
        buckets = Hash.new { |h, k| h[k] = [] }
        fresh.each { |t| buckets[webhook_for(t.category_id)] << embed(t) }
        sent = 0
        all_ok = true
        buckets.each do |(url, header), embeds|
          next if url.blank?
          if post_webhook(url, header, embeds)
            sent += embeds.size
          else
            all_ok = false
          end
        end
        watermark!(newest) if all_ok && newest
        { sent: sent, watermark: watermark }
      end

      # ---------- #ask-the-pros porting (consent-gated) ----------
      CONSENT = "**%{op}** - a moderator thinks this thread is worth putting on the forum, where it stays findable for the next person with the same problem.\n\nReact %{ok} to this message and I'll write it up on home.renovation.reviews, crediting you by the name you use here. Nothing gets posted without that.\n\nEveryone else in the thread: your replies would be included too. If you'd rather be left out, react %{out} and I'll skip your messages."

      def self.reactors(channel, message, emoji)
        r = api(:get, "/channels/#{channel}/messages/#{message}/reactions/#{ERB::Util.url_encode(emoji)}?limit=100")
        (r || []).map { |u| u["id"] }.to_set
      end

      def self.react(channel, message, emoji)
        api(:put, "/channels/#{channel}/messages/#{message}/reactions/#{ERB::Util.url_encode(emoji)}/@me")
      end

      def self.unreact(channel, message, emoji)
        api(:delete, "/channels/#{channel}/messages/#{message}/reactions/#{ERB::Util.url_encode(emoji)}/@me")
      end

      def self.members
        out = []
        after = "0"
        loop do
          batch = api(:get, "/guilds/#{guild}/members?limit=1000&after=#{after}") || []
          break if batch.empty?
          out.concat(batch)
          after = batch.last["user"]["id"]
          break if batch.size < 1000
        end
        out
      end

      def self.staff_ids
        roles = (api(:get, "/guilds/#{guild}/roles") || []).map { |r| [r["id"], r["permissions"].to_i] }.to_h
        powerful = roles.select { |_, p| (p & (MANAGE_MESSAGES | ADMINISTRATOR)) != 0 }.keys.to_set
        ids = Set.new
        owner = (api(:get, "/guilds/#{guild}") || {})["owner_id"]
        ids << owner if owner
        members.each { |m| ids << m["user"]["id"] if (powerful & m["roles"].to_a.to_set).any? }
        ids
      end

      def self.name_of(msg)
        a = msg["author"] || {}
        (msg["member"] || {})["nick"].presence || a["global_name"].presence || a["username"].to_s
      end

      def self.thread_messages(tid)
        out = []
        before = nil
        loop do
          q = "/channels/#{tid}/messages?limit=100" + (before ? "&before=#{before}" : "")
          b = api(:get, q) || []
          break if b.empty?
          out.concat(b)
          before = b.last["id"]
          break if b.size < 100
        end
        out.reverse.reject { |m| m["id"] == tid }
      end

      def self.build_topic(starter, msgs, excluded)
        asker = name_of(starter)
        lines = ["*This started as a question in the [Home Renovation Reviews Discord](#{Forum.base_url}). Reposted here with permission so it stays findable.*", "", "### #{asker} asked", ""]
        body = starter["content"].to_s.strip
        lines.concat(body.blank? ? ["> (no text)"] : body.lines.map { |l| "> #{l.chomp}" })
        lines.concat(["", "### What people said", ""])
        kept = 0
        msgs.each do |m|
          next if m.dig("author", "bot")
          next if excluded.include?(m.dig("author", "id"))
          text = m["content"].to_s.strip
          next if text.length < 15
          lines << "**#{name_of(m)}**"
          lines.concat(text.lines.map(&:chomp))
          lines << ""
          kept += 1
        end
        return [nil, 0] if kept.zero?
        lines.concat(["---", "", "Have the same problem, or a better answer? Reply below - that's the whole point of the place."])
        [lines.join("\n"), kept]
      end

      def self.port!
        return { skipped: "bot not configured" } unless bot?
        ask = SiteSetting.hrr_discord_ask_channel_id.to_s.strip
        return { skipped: "ask channel not set" } if ask.blank?
        me = (api(:get, "/users/@me") || {})["id"]
        return { error: "bot identity unavailable" } unless me
        staff = staff_ids
        threads = ((api(:get, "/guilds/#{guild}/threads/active") || {})["threads"] || []).select { |t| t["parent_id"] == ask }
        arch = api(:get, "/channels/#{ask}/threads/archived/public?limit=50") || {}
        threads += (arch["threads"] || []).select { |t| t["parent_id"] == ask }
        log = []
        threads.each do |t|
          tid = t["id"]
          starter = api(:get, "/channels/#{tid}/messages/#{tid}")
          next unless starter
          marks = (starter["reactions"] || []).map { |r| r.dig("emoji", "name") }.to_set
          next if marks.include?(DONE) && reactors(tid, tid, DONE).include?(me)
          next if marks.include?(NOPE) && reactors(tid, tid, NOPE).include?(me)
          pinned = marks.include?(PIN) ? (reactors(tid, tid, PIN) & staff) : Set.new
          waiting = marks.include?(WAIT) && reactors(tid, tid, WAIT).include?(me)
          next if pinned.empty? && !waiting
          msgs = thread_messages(tid)
          ask_msg = msgs.find { |m| m.dig("author", "id") == me && m["content"].to_s.include?("React") }
          unless waiting
            api(:post, "/channels/#{tid}/messages", { content: format(CONSENT, op: name_of(starter), ok: DONE, out: OUT), allowed_mentions: { parse: [] } })
            react(tid, tid, WAIT)
            log << "[ask] #{t['name'].to_s[0, 50]}"
            next
          end
          next unless ask_msg
          yes = reactors(tid, ask_msg["id"], DONE)
          no = reactors(tid, ask_msg["id"], OUT)
          op = starter.dig("author", "id")
          if no.include?(op)
            react(tid, tid, NOPE)
            unreact(tid, tid, WAIT)
            log << "[nope] #{t['name'].to_s[0, 50]} (author opted out)"
            next
          end
          next unless yes.include?(op)
          raw, kept = build_topic(starter, msgs, no | Set[me])
          next unless raw
          title = t["name"].to_s.gsub(/\s+/, " ").strip[0, 250]
          cat = SiteSetting.hrr_discord_port_category_id.to_i
          pc = ::PostCreator.new(::Discourse.system_user, title: title, raw: raw, category: cat, skip_validations: true)
          post = pc.create
          if pc.errors.any? || post.nil?
            log << "[fail] #{title[0, 50]}: #{pc.errors.full_messages.join(', ')}"
            next
          end
          url = Forum.topic_url(post.topic)
          api(:post, "/channels/#{tid}/messages", { content: "Posted to the forum, credited to everyone who answered - #{url}", allowed_mentions: { parse: [] } })
          react(tid, tid, DONE)
          unreact(tid, tid, WAIT)
          log << "[port] #{title[0, 50]} (#{kept}) -> #{url}"
        end
        { threads: threads.size, log: log }
      end

      # ---------- forum standing -> Discord roles ----------
      HANDLE = /[A-Za-z0-9._]{2,32}/

      def self.roles!
        return { skipped: "bot not configured" } unless bot?
        link_topic = ::Topic.find_by(id: SiteSetting.hrr_discord_link_topic_id.to_i)
        return { skipped: "link topic not set" } unless link_topic
        roles = (api(:get, "/guilds/#{guild}/roles") || []).map { |r| [r["name"], r] }.to_h
        %w[Reno\ Insider Verified\ Reviewer].each { |n| return { error: "role '#{n}' missing" } unless roles[n] }
        board = Http.get_json("#{Forum.base_url}/coin-engine/leaderboard.json") || {}
        rank = (board["users"] || []).map { |u| [u["username"], u["rank"].to_i] }.to_h
        insiders = (::Group.find_by(name: "reno_insiders")&.users&.pluck(:username) || []).to_set
        claims = {}
        seen = Hash.new { |h, k| h[k] = [] }
        ::Post.where(topic_id: link_topic.id, deleted_at: nil).where("post_number > 1").order(:post_number).includes(:user).each do |p|
          m = p.raw.to_s.delete("@").strip[HANDLE]
          next unless m && p.user
          h = m.downcase
          claims[p.user.username] = h
          seen[h] << p.user.username
        end
        dupes = seen.select { |_, owners| owners.size > 1 }
        dupes.each_value { |owners| owners.each { |o| claims.delete(o) } }
        by_handle = {}
        members.each do |m|
          u = m["user"]
          by_handle[u["username"].to_s.downcase] = u["id"]
          by_handle[u["global_name"].to_s.downcase] ||= u["id"] if u["global_name"].present?
        end
        top_n = SiteSetting.hrr_discord_insider_top_n.to_i
        granted = 0
        missing = []
        claims.sort.each do |fu, h|
          mid = by_handle[h]
          unless mid
            missing << "#{fu} -> @#{h}"
            next
          end
          want = []
          want << "Reno Insider" if insiders.include?(fu) || rank.fetch(fu, 10**9) <= top_n
          tl = ::User.find_by(username: fu)&.trust_level.to_i
          want << "Verified Reviewer" if tl >= 2
          want.each do |rn|
            api(:put, "/guilds/#{guild}/members/#{mid}/roles/#{roles[rn]['id']}")
            granted += 1
          end
        end
        { claims: claims.size, granted: granted, missing: missing.first(10), duplicate_handles: dupes.keys.first(10) }
      end
    end
  end
end
