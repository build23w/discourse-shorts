# frozen_string_literal: true
# v0.8.1 — "Watch: <trade> shorts" block in the CRAWLER view of every topic page.
#
# The shorts library (2,000 landing pages) was reachable from crawlable HTML
# only through the estate footer and /shorts/browse. Real users see the theme's
# in-feed shorts, but that is client JS — bots never see a single topic → short
# link. This renders 6 same-trade shorts after the posts of every topic in the
# server-side crawler layout (`server:topic-show-after-posts-crawler`), which is
# also what the Worker's anonymous cache stores for the crawler view. Cheap:
# one cached query per trade area every 15 minutes.
module DiscourseShorts
  module CrawlerLinks
    def self.html_for(ctx)
      tv = ctx.instance_variable_get(:@topic_view)
      tv ||= (ctx.respond_to?(:controller) ? ctx.controller.instance_variable_get(:@topic_view) : nil)
      topic = tv&.topic
      return "" unless topic
      return "" if topic.category_id.to_i == 423 # the shorts' own discussion topics
      cat_name = (topic.category&.name).to_s
      tags = (topic.tags.map(&:name) rescue [])
      area, _lvl = Journey.classify(title: "#{topic.title} #{cat_name}", tags: tags)
      shorts = Discourse.cache.fetch("discourse-shorts:crawler-links:#{area}", expires_in: 15.minutes) do
        rows = Short.where(status: "approved")
        rows = rows.where(category: area) if area != "general"
        rows = rows.order(Arel.sql("(likes - dislikes) DESC, views DESC, id DESC")).limit(6).to_a
        rows = Short.where(status: "approved").order(views: :desc).limit(6).to_a if rows.length < 3
        rows.map do |s|
          {
            id: s.video_id,
            title: s.title.to_s[0, 70],
            thumb: (Media.cdn(s.poster_url.presence) || (s.provider == "youtube" ? "https://i.ytimg.com/vi/#{s.video_id}/mqdefault.jpg" : nil)),
          }
        end
      end
      return "" if shorts.blank?
      base = Discourse.base_url
      e = ->(x) { ERB::Util.html_escape(x.to_s) }
      label = Journey::AREA_LABELS[area] || "Renovation"
      items = shorts.map do |s|
        img = s[:thumb].present? ? %(<img src="#{e.call(s[:thumb])}" alt="" width="120" height="213" loading="lazy"> ) : ""
        %(<li>#{img}<a href="#{base}/shorts/v/#{ERB::Util.url_encode(s[:id])}">#{e.call(s[:title])}</a></li>)
      end.join
      <<~HTML
        <section class="lf-crawler-shorts" itemscope itemtype="https://schema.org/ItemList">
          <h3>Watch: #{e.call(label)} renovation shorts</h3>
          <ul>#{items}</ul>
          <p><a href="#{base}/shorts/browse">Browse every renovation short by trade</a></p>
        </section>
      HTML
    rescue StandardError => e
      Rails.logger.warn("[discourse-shorts] crawler links failed: #{e.message}")
      ""
    end
  end
end
