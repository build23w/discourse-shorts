# frozen_string_literal: true
# v0.9.0 — the desk's hands on the forum itself: who posts, what is waiting,
# what earns clicks, and the guarded write paths (reply, new topic, unlist, FAQ
# index, IndexNow ping, staff log). Everything that used to be hrr_desk.py, done
# in-process with the Discourse models instead of the admin API.
module DiscourseShorts
  module Desk
    module Forum
      STORE = Ai::STORE
      INDEX_START = "<!-- crew-answers:start -->"
      INDEX_END = "<!-- crew-answers:end -->"
      INDEX_MAX = 8
      REPLY_GUARD_DAYS = 14
      REFRESH_SKIP_TITLE = ["reno degen", "$reno", "crypto", "token", "airdrop", "wallet", "discord", "admin change log", "start here", "most commonly asked"].freeze
      DIRECTORY_PARENTS = [5, 6].freeze # Canada / United States: province & state subcats hold contractor profiles

      def self.poster
        ::User.find_by(username_lower: SiteSetting.hrr_desk_poster.to_s.strip.downcase) || ::Discourse.system_user
      end

      def self.skip_categories
        SiteSetting.hrr_desk_skip_categories.to_s.split("|").map(&:to_i).reject(&:zero?)
      end

      def self.house_users
        SiteSetting.hrr_desk_house_users.to_s.split("|").map { |u| u.strip.downcase }.reject(&:blank?)
      end

      def self.base_url
        ::Discourse.base_url
      end

      def self.topic_url(topic)
        "#{base_url}/t/#{topic.slug}/#{topic.id}"
      end

      # Member-started topics with no replies, 1h..10d old, outside house/skip categories.
      def self.candidates(limit: 12)
        house_ids = ::User.where(username_lower: house_users).pluck(:id)
        ::Topic.where(archetype: ::Archetype.default, visible: true, closed: false, archived: false, deleted_at: nil)
               .where(posts_count: 1)
               .where("topics.created_at BETWEEN ? AND ?", 10.days.ago, 1.hour.ago)
               .where.not(category_id: skip_categories)
               .where.not(user_id: house_ids)
               .where(pinned_globally: false)
               .order(created_at: :asc)
               .limit(limit).to_a
      end

      # Topics earning referral clicks (30d) without a poster reply in 90d.
      def self.refresh_candidates(limit: 12)
        today = Date.today
        report = ::Report.find("top_referred_topics", start_date: (today - 30).to_time, end_date: today.to_time.end_of_day, limit: 50)
        rows = (report && report.data) || []
        me = poster
        parent = ::Category.pluck(:id, :parent_category_id).to_h
        out = []
        rows.each do |r|
          title = r[:topic_title].to_s
          next if REFRESH_SKIP_TITLE.any? { |k| title.downcase.include?(k) }
          t = ::Topic.find_by(id: r[:topic_id], deleted_at: nil)
          next unless t && t.archetype == ::Archetype.default && !t.closed && !t.archived && t.visible
          cid = t.category_id
          next if skip_categories.include?(cid) || DIRECTORY_PARENTS.include?(cid) || DIRECTORY_PARENTS.include?(parent[cid])
          next if t.category&.read_restricted
          next if t.posts_count.to_i > 40
          next if ::Post.where(topic_id: t.id, user_id: me.id).where("created_at > ?", 90.days.ago).exists?
          out << { topic: t, clicks: r[:num_clicks].to_i }
          break if out.size >= limit
        end
        out.sort_by { |h| -h[:clicks] }
      rescue StandardError => e
        Rails.logger.warn("[hrr-desk] refresh_candidates failed: #{e.class} #{e.message}")
        []
      end

      # Plain-text transcript of a thread (first post + up to `tail` most recent replies).
      def self.transcript(topic, tail: 12, max_chars: 6000)
        posts = ::Post.where(topic_id: topic.id, deleted_at: nil).where("COALESCE(hidden,false) = false").order(:post_number)
        first = posts.first
        rest = posts.where("post_number > 1").last(tail)
        lines = ["Title: #{topic.title}", "Category: #{topic.category&.name}", "Tags: #{topic.tags.pluck(:name).join(', ')}", ""]
        ([first] + rest).compact.each do |p|
          lines << "#{p.user&.username || 'member'} (post #{p.post_number}, #{p.created_at.to_date}):"
          lines << p.raw.to_s.gsub(/\s+/, " ").strip[0, 2500]
          lines << ""
        end
        lines.join("\n")[0, max_chars]
      end

      def self.recently_replied?(topic, user = poster, days: REPLY_GUARD_DAYS)
        ::Post.where(topic_id: topic.id, user_id: user.id).where("created_at > ?", days.days.ago).exists?
      end

      def self.recent_titles(days: 90, limit: 80)
        mine = ::Topic.where(user_id: poster.id).where("created_at > ?", days.days.ago).order(created_at: :desc).limit(limit).pluck(:title)
        latest = ::Topic.where(archetype: ::Archetype.default, visible: true).where("created_at > ?", 14.days.ago)
                        .where.not(category_id: skip_categories).order(created_at: :desc).limit(30).pluck(:title)
        (mine + latest).uniq
      end

      # Same-question dupe check: all long words of the title present in an existing title (90d).
      def self.duplicate?(title)
        words = title.to_s.downcase.scan(/[a-z][a-z\-]{4,}/).uniq - %w[should there their about which would could where these those toronto ontario canada]
        words = words.first(4)
        return false if words.size < 2
        scope = ::Topic.where("created_at > ?", 90.days.ago).where(archetype: ::Archetype.default)
        words.each { |w| scope = scope.where("LOWER(title) LIKE ?", "%#{w}%") }
        scope.exists?
      end

      def self.reply!(topic, raw, user: poster, min_length: 200)
        return { skipped: "poster already replied within #{REPLY_GUARD_DAYS} days" } if recently_replied?(topic, user)
        return { error: "reply too short" } if raw.to_s.strip.length < min_length
        pc = ::PostCreator.new(user, topic_id: topic.id, raw: raw.to_s.strip, skip_validations: true)
        post = pc.create
        return { error: pc.errors.full_messages.join(", ") } if pc.errors.any? || post.nil?
        url = "#{topic_url(topic)}/#{post.post_number}"
        { url: url, post_id: post.id, indexnow: indexnow(topic_url(topic)) }
      end

      def self.new_topic!(title:, raw:, category_id:, tags: [], user: poster)
        pc = ::PostCreator.new(user, title: title.to_s.strip, raw: raw.to_s.strip, category: category_id.to_i, skip_validations: true)
        post = pc.create
        return { error: pc.errors.full_messages.join(", ") } if pc.errors.any? || post.nil?
        topic = post.topic
        begin
          names = Array(tags).map { |t| t.to_s.downcase.strip.gsub(/[^a-z0-9\-]/, "") }.reject(&:blank?).first(5)
          ::DiscourseTagging.tag_topic_by_names(topic, ::Guardian.new(::Discourse.system_user), names) if names.any?
        rescue StandardError => e
          Rails.logger.warn("[hrr-desk] tagging failed: #{e.message}")
        end
        url = topic_url(topic)
        out = { url: url, topic_id: topic.id, indexnow: indexnow(url) }
        out[:index] = index_add(title, url)
        out
      end

      # Reversible: hide from lists and file under Promo (7). Never deletes.
      def self.unlist!(topic, reason)
        topic.update_status("visible", false, ::Discourse.system_user)
        promo = SiteSetting.hrr_desk_promo_category_id.to_i
        topic.change_category_to_id(promo) if promo > 0 && ::Category.exists?(id: promo)
        { unlisted: topic.id, reason: reason }
      rescue StandardError => e
        { error: "unlist failed: #{e.message}" }
      end

      # Keep the "Newest answers from the crew" block in the pinned FAQ current.
      def self.index_add(title, url)
        pid = SiteSetting.hrr_desk_faq_post_id.to_i
        return "faq post not set" if pid <= 0
        post = ::Post.find_by(id: pid)
        return "faq post missing" unless post
        raw = post.raw.to_s
        return "no marker block" unless raw.include?(INDEX_START) && raw.include?(INDEX_END)
        head, rest = raw.split(INDEX_START, 2)
        block, tail = rest.split(INDEX_END, 2)
        links = block.to_s.lines.map { |l| l.sub(/\A>\s?/, "").strip }.select { |l| l.start_with?("- [") && !l.include?(url) }
        links.unshift("- [#{title.gsub(']', '')}](#{url})")
        body = "\n> **Newest answers from the crew** (one researched question a day)\n" + links.first(INDEX_MAX).map { |l| "> #{l}" }.join("\n") + "\n"
        new_raw = head + INDEX_START + body + INDEX_END + tail.to_s
        ::PostRevisor.new(post, post.topic).revise!(::Discourse.system_user, { raw: new_raw, edit_reason: "crew answers index" },
                                                    skip_validations: true, bypass_bump: true)
        "updated"
      rescue StandardError => e
        "index failed: #{e.message}"
      end

      def self.indexnow(url)
        key = SiteSetting.hrr_desk_indexnow_key.to_s.strip
        return "no key" if key.blank?
        host = URI(base_url).host
        code, _ = Http.post_json("https://api.indexnow.org/indexnow",
                                 { host: host, key: key, keyLocation: "#{base_url}/#{key}.txt", urlList: [url] }, timeout: 20, retries: 0)
        code
      end

      # Staff log topic (created on first use in the staff category).
      def self.log_topic
        tid = SiteSetting.hrr_desk_log_topic_id.to_i
        topic = tid > 0 ? ::Topic.find_by(id: tid) : nil
        return topic if topic
        stored = PluginStore.get(STORE, "log-topic-id").to_i
        topic = ::Topic.find_by(id: stored) if stored > 0
        return topic if topic
        cat = SiteSetting.hrr_desk_staff_category_id.to_i
        return nil unless cat > 0 && ::Category.exists?(id: cat)
        pc = ::PostCreator.new(::Discourse.system_user, title: "HRR desk log (server-side jobs)",
                               raw: "Run log for the discourse-shorts desk jobs (daily topic, answer desk, refresh desk, shirt feed, Discord). One reply per run that did something. Do not delete.",
                               category: cat, skip_validations: true)
        post = pc.create
        return nil if pc.errors.any? || post.nil?
        PluginStore.set(STORE, "log-topic-id", post.topic_id)
        post.topic
      rescue StandardError => e
        Rails.logger.warn("[hrr-desk] log topic failed: #{e.message}")
        nil
      end

      def self.log!(job, lines)
        text = Array(lines).flatten.compact.map(&:to_s).reject(&:blank?)
        return if text.empty?
        Rails.logger.info("[hrr-desk] #{job}: #{text.join(' | ')[0, 900]}")
        topic = log_topic
        return unless topic
        raw = "**#{job}** — #{Time.now.utc.strftime('%Y-%m-%d %H:%M UTC')}\n\n" + text.map { |l| "- #{l}" }.join("\n")
        pc = ::PostCreator.new(::Discourse.system_user, topic_id: topic.id, raw: raw, skip_validations: true)
        pc.create
      rescue StandardError => e
        Rails.logger.warn("[hrr-desk] log! failed: #{e.message}")
      end

      def self.day_key(key)
        "#{key}-#{Time.now.utc.strftime('%Y-%m-%d')}"
      end

      def self.done_today?(key)
        !!PluginStore.get(STORE, day_key(key))
      end

      def self.mark_today!(key)
        PluginStore.set(STORE, day_key(key), Time.now.to_i)
      end

      # Claim today's slot (returns false if already claimed).
      def self.once_per_day?(key)
        return false if done_today?(key)
        mark_today!(key)
        true
      end
    end
  end
end
