# frozen_string_literal: true
# v0.9.0 — Shirt Lab curator, server-side. Two things, ported from
# shirt_curator.py (2026-09-06):
#   feed!   — read shirtlab.lol's marketing sitemap + each share's manifest +
#             live catalog prices, store the carousel feed in PluginStore; the
#             theme component reads it from GET /shorts/shirt-feed.json (and the
#             theme setting stays as the fallback).
#   ideas!  — weekly: ask the model for 4-6 typography-only shirt ideas from this
#             week's headlines + the forum's live themes, validate the shape the
#             renderer expects, and rewrite the private Staff topic so Garrett can
#             render + publish with one command. Nothing is ever published from
#             here (the admin publishing key never leaves Garrett's PC).
module DiscourseShorts
  module Desk
    module ShirtLab
      STORE = Ai::STORE
      FEED_KEY = "shirt-feed"
      MAX_ITEMS = 10
      IDEAS_TITLE = "Shirt Lab - next batch ideas (curator)"

      def self.lab
        SiteSetting.hrr_shirt_lab_url.to_s.strip.sub(%r{/\z}, "").presence || "https://shirtlab.lol"
      end

      def self.split_title(title)
        parts = title.to_s.split(/\s+[—–-]{1,2}\s+/).map(&:strip).reject(&:blank?)
        return ["", title.to_s] if parts.size < 2
        tagpart = parts.find { |p| p =~ /\b(shirt|tee|hoodie|sweatshirt|tank|hat|cap)\b/i } || parts[0]
        name = parts.find { |p| !p.equal?(tagpart) } || parts[-1]
        tag = tagpart.gsub(/\b(funny|shirt|tee|hoodie|sweatshirt|tank|hat|cap|fan|design)\b/i, "").gsub(/\s+/, " ").strip.gsub(/\A[\s,\-]+|[\s,\-]+\z/, "")
        [tag[0, 24], name[0, 60]]
      end

      def self.marketing_share_ids
        ids = []
        code, raw = Http.get("#{lab}/sitemap-marketing.xml", timeout: 20)
        files = code == 200 ? raw.scan(%r{<loc>([^<]+)</loc>}).flatten : []
        files = ["#{lab}/sitemap-marketing-1.xml"] if files.empty?
        files.first(5).each do |f|
          c, body = Http.get(f, timeout: 20)
          next unless c == 200
          ids.concat(body.scan(%r{/s/([a-f0-9]{32})}).flatten)
        end
        ids.uniq
      end

      def self.price_map
        cat = Http.get_json("#{lab}/api/catalog", timeout: 20)
        return [{}, nil] unless cat.is_a?(Hash)
        margin = ((cat["pricing"] || {})["profitMarginUsd"] || 0).to_f
        prices = (cat["products"] || []).map { |p| [p["id"], (p["retailPrice"] || p["basePrice"] || 0).to_f + margin] }.to_h
        [prices, cat["currency"] || "USD"]
      end

      def self.build_feed
        prices, _cur = price_map
        items = []
        marketing_share_ids.first(40).each do |sid|
          m = Http.get_json("#{lab}/api/shares/#{sid}", timeout: 20)
          next unless m.is_a?(Hash) && m["visibility"] == "marketing"
          tag, name = split_title(m["title"])
          price = prices[(m["product"] || {})["id"]]
          items << { "id" => sid, "title" => name, "tag" => tag, "price" => (price ? format("from US$%.2f", price) : ""), "created" => m["createdAt"].to_s }
        end
        items.sort_by! { |i| i["created"] }.reverse!
        items.each { |i| i.delete("created") }
        { "updated" => Time.now.utc.iso8601, "items" => items.first(MAX_ITEMS) }
      end

      def self.feed
        f = PluginStore.get(STORE, FEED_KEY)
        f.is_a?(Hash) ? f : nil
      end

      def self.feed!
        return { skipped: "disabled" } unless SiteSetting.hrr_shirt_feed_enabled
        new_feed = build_feed
        return { skipped: "fewer than 3 marketing shares readable (#{new_feed['items'].size}); feed left unchanged" } if new_feed["items"].size < 3
        PluginStore.set(STORE, FEED_KEY, new_feed)
        { items: new_feed["items"].size, first: new_feed["items"].first(3).map { |i| i["title"] } }
      end

      # ---------- weekly ideas ----------
      def self.ideas_topic
        tid = SiteSetting.hrr_shirt_ideas_topic_id.to_i
        t = tid > 0 ? ::Topic.find_by(id: tid) : nil
        t ||= ::Topic.where(title: IDEAS_TITLE).order(:id).first
        t
      end

      def self.valid_idea?(i)
        return false unless i.is_a?(Hash)
        lines = Array(i["lines"]).map(&:to_s)
        return false unless lines.size.between?(3, 4) && lines.all? { |l| l.length.between?(2, 12) }
        return false unless i["slug"].to_s =~ /\A[a-z0-9]+(?:-[a-z0-9]+){0,6}\z/
        return false unless i["title"].to_s.length.between?(10, 80) && i["description"].to_s.length.between?(20, 240)
        return false unless i["accent"].to_s =~ /\A#[0-9a-fA-F]{6}\z/
        return false unless i["footer"].to_s.length.between?(3, 40)
        true
      end

      def self.ideas!
        return { skipped: "ai disabled" } unless Ai.enabled? && SiteSetting.hrr_shirt_ideas_enabled
        existing = ideas_topic
        prior = existing ? ::Post.where(topic_id: existing.id, post_number: 1).pick(:raw).to_s.scan(/"lines":\s*\[([^\]]*)\]/).flatten.first(30) : []
        live = (feed || {})["items"].to_a.map { |i| i["title"] }
        forum_titles = ::Topic.where(archetype: ::Archetype.default, visible: true).where.not(category_id: Forum.skip_categories)
                              .order(created_at: :desc).limit(30).pluck(:title)
        today = Date.today
        prompt = <<~TXT
          Date: #{today.strftime('%-d %B %Y')}. Propose 4 to 6 t-shirt ideas for Shirt Lab (shirtlab.lol), sold to readers of home.renovation.reviews: Greater Toronto homeowners mid-renovation, DIYers and trades.

          This week's Toronto headlines:
          #{Sources.headlines_text(limit: 14)}

          Live themes on the forum:
          #{forum_titles.map { |t| "- #{t}" }.join("\n")}

          Shirts already on sale (do not repeat): #{live.join(' | ')}
          Lines already proposed before (do not repeat): #{prior.join(' | ')}

          Rules: typography only — the renderer sets 3 or 4 UPPERCASE lines on a black tee with one accent colour and a short caption; every line at most 12 characters; titles at most 80 characters in the form "<Kind> Shirt — <Line text>"; descriptions at most 240 characters and must include "remix the wording or colours before you order" and "Original artwork, no brands"; no brand names, team names, logos, celebrity names, city crests or anyone's slogans; no politics beyond gentle news-consumption humour; nothing that mocks a group; Canadian spelling. At least half must be renovation/homeowner/trade humour; the rest may ride a seasonal or local moment. "signal" is one honest sentence about the evidence.

          Reply with ONLY JSON: {"batch": "#{today.iso8601}-<word>", "ideas": [{"slug": "kebab-case", "title": "...", "description": "...", "lines": ["...", "...", "..."], "accent": "#hex", "footer": "SHORT CAPTION", "signal": "...", "sources": ["url"]}]}
        TXT
        spec = Ai.chat(system: "You are a merch curator for a Canadian home renovation community. JSON only.", user: prompt, max_tokens: 1500, json: true, temperature: 0.8)
        return { error: "no ideas" } unless spec.is_a?(Hash) && spec["ideas"].is_a?(Array)
        ideas = spec["ideas"].select { |i| valid_idea?(i) }.first(6)
        return { skipped: "only #{ideas.size} valid ideas" } if ideas.size < 3
        batch = spec["batch"].to_s[/\A[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9\-]{2,24}\z/] || "#{today.iso8601}-curator"
        rows = ["| # | Slug | Lines | Accent | Footer | Trend signal | Source |", "|---|---|---|---|---|---|---|"]
        ideas.each_with_index do |it, i|
          rows << "| #{i + 1} | `#{it['slug']}` | #{Array(it['lines']).join(' / ')} | `#{it['accent']}` | #{it['footer']} | #{it['signal'].to_s[0, 160]} | #{Array(it['sources']).first(2).join(' ')} |"
        end
        body = "Prepared #{today.iso8601} by the server-side Shirt Lab curator (discourse-shorts desk). These are proposals in the shape `scripts/marketing-batch.mjs` expects (`IDEAS` entries). Nothing is rendered or published until someone runs the batch on the PC that holds the admin publishing key (`shirt-lab-batches/publish-batch.ps1 -Publish`).\n\n" +
               rows.join("\n") + "\n\n```json\n" + JSON.pretty_generate({ "batch" => batch, "audience" => "home.renovation.reviews readers: GTA homeowners mid-renovation, DIYers, trades", "ideas" => ideas })[0, 12_000] + "\n```\n"
        if existing
          post = ::Post.find_by(topic_id: existing.id, post_number: 1)
          ::PostRevisor.new(post, existing).revise!(::Discourse.system_user, { raw: body, edit_reason: "curator refresh" }, skip_validations: true, bypass_bump: true)
          { topic_id: existing.id, updated: true, ideas: ideas.map { |i| i["slug"] } }
        else
          cat = SiteSetting.hrr_desk_staff_category_id.to_i
          pc = ::PostCreator.new(Forum.poster, title: IDEAS_TITLE, raw: body, category: cat, skip_validations: true)
          post = pc.create
          return { error: pc.errors.full_messages.join(", ") } if pc.errors.any? || post.nil?
          { topic_id: post.topic_id, created: true, ideas: ideas.map { |i| i["slug"] } }
        end
      end
    end
  end
end
