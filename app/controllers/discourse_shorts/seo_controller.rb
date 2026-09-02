# frozen_string_literal: true
# v0.7.0 — the indexable face of the shorts library.
#
# Until now the only server-rendered page per short was an OpenGraph stub that
# 302'd humans into the app and showed crawlers a spinner, and nothing linked to
# the shorts from crawlable HTML — so 400 videos were invisible to Google.
# This controller serves the SAME content to everyone (no UA branching, no
# cloaking surface):
#   GET /shorts/v/:video_id   — a landing page per short: inline player, title,
#                               creator, VideoObject JSON-LD, related shorts,
#                               links into the app viewer / discussion / browse
#   GET /shorts/browse        — a plain HTML index of every approved short,
#                               grouped by trade, linking to the landing pages
#   GET /shorts/sitemap.xml   — a Google video sitemap of the same pages
# Discourse's CSP forbids inline <script>, so these pages carry no JS at all;
# inline <style> is allowed and is all they need.
module DiscourseShorts
  class SeoController < ::ApplicationController
    requires_plugin ::DiscourseShorts::PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required, raise: false
    skip_before_action :preload_json, raise: false

    RELATED_N = 8
    SITEMAP_MAX = 2000

    def landing
      s = Short.find_by(video_id: params[:video_id]) or raise Discourse::NotFound
      raise Discourse::NotFound unless s.status == "approved"
      base = Discourse.base_url
      e = ->(x) { ERB::Util.html_escape(x.to_s) }

      title = (s.title.presence || "Renovation short").to_s[0, 120]
      owner = s.submitted_by_id ? ::User.find_by(id: s.submitted_by_id) : nil
      house = s.source == "owned" || (owner && owner.staff?)
      creator = house ? "LF Builders" : (owner ? "@#{owner.username}" : "the community")
      creator_url = owner ? "#{base}/u/#{ERB::Util.url_encode(owner.username)}" : "#{base}/watch"
      cat = s.try(:category).presence || (Journey.classify(title: s.title.to_s, tags: Array(s.tag_list)).first rescue "general")
      cat_label = Journey::AREA_LABELS[cat] || cat.to_s.tr("-", " ").capitalize
      tags = Array(s.tag_list).reject { |t| t.to_s.end_with?("-shorts") }.first(6)
      poster = Media.cdn(s.poster_url.presence) ||
               (s.provider == "youtube" ? "https://i.ytimg.com/vi/#{s.video_id}/hqdefault.jpg" : "#{base}/uploads/default/original/1X/logo.png")
      video_url = s.provider == "upload" ? Media.cdn(s.video_url) : nil
      embed_url = s.provider == "youtube" ? "https://www.youtube.com/embed/#{s.video_id}?playsinline=1&rel=0" : nil
      self_url = "#{base}/shorts/v/#{ERB::Util.url_encode(s.video_id)}"
      viewer = "#{base}/?short=#{ERB::Util.url_encode(s.video_id)}&utm_source=lf_short&utm_medium=landing"
      topic_url = s.topic_id.to_i > 0 ? "#{base}/t/#{s.topic_id}" : nil
      desc = "#{cat_label} short by #{creator} on Home Renovation Reviews, Canada's home renovation community. " \
             "Watch, react, and ask the trades who do this work every day."
      uploaded = (s.created_at || Time.zone.now).iso8601

      related = Short.where(status: "approved").where.not(id: s.id)
      related = related.where(category: cat) if s.respond_to?(:category) && cat.present?
      related = related.order(Arel.sql("(likes - dislikes) DESC, views DESC, id DESC")).limit(RELATED_N).to_a
      if related.length < 4
        more = Short.where(status: "approved").where.not(id: [s.id] + related.map(&:id)).order(views: :desc).limit(RELATED_N - related.length).to_a
        related += more
      end

      ld = {
        "@context" => "https://schema.org",
        "@type" => "VideoObject",
        "name" => title,
        "description" => desc,
        "thumbnailUrl" => [poster],
        "uploadDate" => uploaded,
        "url" => self_url,
        "publisher" => { "@type" => "Organization", "name" => "Home Renovation Reviews", "url" => base },
        "interactionStatistic" => [
          { "@type" => "InteractionCounter", "interactionType" => "https://schema.org/WatchAction", "userInteractionCount" => s.views.to_i },
          { "@type" => "InteractionCounter", "interactionType" => "https://schema.org/LikeAction", "userInteractionCount" => s.likes.to_i }
        ]
      }
      ld["contentUrl"] = video_url if video_url
      ld["embedUrl"] = embed_url if embed_url
      ld["author"] = { "@type" => house ? "Organization" : "Person", "name" => house ? "LF Builders" : (owner&.name.presence || owner&.username || "Community member"), "url" => creator_url }

      player =
        if video_url
          %(<video class="pl" controls playsinline preload="metadata" poster="#{e.call(poster)}" src="#{e.call(video_url)}"></video>)
        else
          %(<iframe class="pl" src="#{e.call(embed_url)}" title="#{e.call(title)}" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen loading="lazy" referrerpolicy="strict-origin-when-cross-origin"></iframe>)
        end

      rel_html = related.map do |r|
        thumb = Media.cdn(r.poster_url.presence) || (r.provider == "youtube" ? "https://i.ytimg.com/vi/#{r.video_id}/hqdefault.jpg" : poster)
        %(<a class="rc" href="#{e.call("#{base}/shorts/v/#{ERB::Util.url_encode(r.video_id)}")}"><img loading="lazy" src="#{e.call(thumb)}" alt=""><span>#{e.call(r.title.to_s[0, 70])}</span></a>)
      end.join

      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <title>#{e.call(title)} — Renovation Shorts | Home Renovation Reviews</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="description" content="#{e.call(desc)}">
        <link rel="canonical" href="#{e.call(self_url)}">
        <meta property="og:type" content="video.other">
        <meta property="og:site_name" content="Home Renovation Reviews">
        <meta property="og:title" content="#{e.call(title)}">
        <meta property="og:description" content="#{e.call(desc)}">
        <meta property="og:image" content="#{e.call(poster)}">
        <meta property="og:url" content="#{e.call(self_url)}">
        #{embed_url ? %(<meta property="og:video" content="#{e.call(embed_url)}"><meta property="og:video:type" content="text/html"><meta property="og:video:width" content="720"><meta property="og:video:height" content="1280">) : ""}
        #{video_url ? %(<meta property="og:video" content="#{e.call(video_url)}"><meta property="og:video:type" content="video/mp4"><meta property="og:video:width" content="720"><meta property="og:video:height" content="1280">) : ""}
        <meta name="twitter:card" content="summary_large_image">
        <meta name="twitter:title" content="#{e.call(title)}">
        <meta name="twitter:description" content="#{e.call(desc)}">
        <meta name="twitter:image" content="#{e.call(poster)}">
        <script type="application/ld+json">#{ld.to_json}</script>
        <style>
          :root{color-scheme:light}
          body{margin:0;background:#f5f6f8;color:#1c2b46;font-family:system-ui,Segoe UI,Arial,sans-serif;line-height:1.4}
          a{color:#0a7d77}
          .top{background:#fff;border-bottom:1px solid #e4e6ea;padding:12px 16px;display:flex;gap:14px;align-items:center;font-weight:800}
          .top a{text-decoration:none;color:#1c2b46}
          .top .b{margin-left:auto;font-weight:600;font-size:14px}
          main{max-width:980px;margin:0 auto;padding:18px 16px 40px;display:grid;grid-template-columns:minmax(0,380px) 1fr;gap:22px}
          @media(max-width:760px){main{grid-template-columns:1fr}}
          .stage{background:#000;aspect-ratio:9/16;max-height:70vh;display:flex;align-items:center;justify-content:center}
          .pl{width:100%;height:100%;border:0;display:block;object-fit:contain;background:#000}
          h1{font-size:22px;margin:0 0 6px;line-height:1.25}
          .meta{font-size:14px;color:#556;margin:0 0 14px}
          .meta a{font-weight:700}
          .btn{display:inline-block;background:#111;color:#fff;text-decoration:none;font-weight:800;padding:12px 18px;margin:0 8px 8px 0;font-size:14px}
          .btn.alt{background:#fff;color:#1c2b46;border:1px solid #cfd3d9}
          .chips span{display:inline-block;background:#fff;border:1px solid #d9dde3;padding:3px 9px;font-size:12px;margin:0 6px 6px 0;text-transform:capitalize}
          .desc{font-size:15px;margin:14px 0 18px}
          h2{font-size:16px;margin:26px 0 10px}
          .rel{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:10px}
          .rc{display:block;text-decoration:none;color:#1c2b46;font-size:12.5px;font-weight:600}
          .rc img{width:100%;aspect-ratio:9/16;object-fit:cover;background:#111;display:block;margin-bottom:5px}
          footer{max-width:980px;margin:0 auto;padding:0 16px 30px;font-size:13px;color:#667}
        </style>
        </head><body>
        <div class="top"><a href="#{e.call(base)}/">Home Renovation Reviews</a><a class="b" href="#{e.call(base)}/shorts/browse">All shorts</a></div>
        <main>
          <div class="stage">#{player}</div>
          <section>
            <h1>#{e.call(title)}</h1>
            <p class="meta">#{e.call(cat_label)} · by <a href="#{e.call(creator_url)}">#{e.call(creator)}</a> · #{s.views.to_i} views · #{s.likes.to_i} likes</p>
            <p>
              <a class="btn" href="#{e.call(viewer)}">▶ Watch in the Shorts feed</a>
              #{topic_url ? %(<a class="btn alt" href="#{e.call(topic_url)}">💬 Discussion (#{s.comment_count.to_i})</a>) : %(<a class="btn alt" href="#{e.call(viewer)}">💬 Comment</a>)}
            </p>
            <p class="desc">#{e.call(desc)}</p>
            <div class="chips">#{tags.map { |t| "<span>#{e.call(t)}</span>" }.join}</div>
            <h2>More #{e.call(cat_label.downcase)} shorts</h2>
            <div class="rel">#{rel_html}</div>
            <p style="margin-top:18px"><a href="#{e.call(base)}/watch">Browse every short by trade →</a></p>
          </section>
        </main>
        <footer>Short-form renovation videos from Canadian homeowners and trades. Free account · <a href="#{e.call(base)}/signup">join to upload your own</a>.</footer>
        </body></html>
      HTML
      response.headers["Cache-Control"] = "public, max-age=300"
      render html: html.html_safe, content_type: "text/html", layout: false
    end

    def browse
      base = Discourse.base_url
      e = ->(x) { ERB::Util.html_escape(x.to_s) }
      rows = Short.where(status: "approved").order(Arel.sql("(likes - dislikes) DESC, views DESC, id DESC")).limit(SITEMAP_MAX).to_a
      groups = rows.group_by { |s| s.try(:category).presence || "general" }
      sections = groups.sort_by { |k, v| -v.length }.map do |cat, list|
        label = Journey::AREA_LABELS[cat] || cat.to_s.tr("-", " ").capitalize
        items = list.map do |s|
          thumb = Media.cdn(s.poster_url.presence) || (s.provider == "youtube" ? "https://i.ytimg.com/vi/#{s.video_id}/mqdefault.jpg" : "")
          %(<li><a href="#{e.call("#{base}/shorts/v/#{ERB::Util.url_encode(s.video_id)}")}">#{thumb.present? ? %(<img loading="lazy" src="#{e.call(thumb)}" alt="">) : ""}<span>#{e.call(s.title.to_s[0, 80])}</span></a></li>)
        end.join
        %(<section><h2 id="#{e.call(cat)}">#{e.call(label)} <small>#{list.length}</small></h2><ul>#{items}</ul></section>)
      end.join
      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <title>Renovation Shorts — #{rows.length} short videos by trade | Home Renovation Reviews</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="description" content="Browse #{rows.length} short renovation videos — kitchens, bathrooms, tiling, concrete, roofing and more — from Canadian homeowners and the trades on Home Renovation Reviews.">
        <link rel="canonical" href="#{e.call(base)}/shorts/browse">
        <style>
          body{margin:0;background:#f5f6f8;color:#1c2b46;font-family:system-ui,Segoe UI,Arial,sans-serif}
          .top{background:#fff;border-bottom:1px solid #e4e6ea;padding:12px 16px;font-weight:800}
          .top a{text-decoration:none;color:#1c2b46}
          main{max-width:1100px;margin:0 auto;padding:16px}
          h1{font-size:24px;margin:8px 0 4px} .lead{color:#556;margin:0 0 16px}
          h2{font-size:17px;margin:22px 0 8px} h2 small{color:#889;font-weight:600}
          ul{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:10px}
          li a{display:block;text-decoration:none;color:#1c2b46;font-size:12.5px;font-weight:600}
          li img{width:100%;aspect-ratio:9/16;object-fit:cover;background:#111;display:block;margin-bottom:4px}
          .app{display:inline-block;background:#111;color:#fff;text-decoration:none;font-weight:800;padding:10px 16px;margin:6px 0 10px}
        </style>
        </head><body>
        <div class="top"><a href="#{e.call(base)}/">Home Renovation Reviews</a></div>
        <main>
          <h1>Renovation Shorts</h1>
          <p class="lead">#{rows.length} short videos from real renovations, grouped by trade. Tap any short for its page, or open the full-screen feed.</p>
          <a class="app" href="#{e.call(base)}/watch">▶ Open the Shorts feed</a>
          #{sections}
        </main>
        </body></html>
      HTML
      response.headers["Cache-Control"] = "public, max-age=900"
      render html: html.html_safe, content_type: "text/html", layout: false
    end

    def sitemap
      base = Discourse.base_url
      e = ->(x) { ERB::Util.html_escape(x.to_s) }
      rows = Short.where(status: "approved").order(id: :desc).limit(SITEMAP_MAX).to_a
      urls = rows.map do |s|
        loc = "#{base}/shorts/v/#{ERB::Util.url_encode(s.video_id)}"
        poster = Media.cdn(s.poster_url.presence) || (s.provider == "youtube" ? "https://i.ytimg.com/vi/#{s.video_id}/hqdefault.jpg" : nil)
        title = (s.title.presence || "Renovation short").to_s[0, 100]
        cat = s.try(:category).presence || "general"
        desc = "#{Journey::AREA_LABELS[cat] || cat} short on Home Renovation Reviews"
        media = s.provider == "upload" ? "<video:content_loc>#{e.call(Media.cdn(s.video_url))}</video:content_loc>" : "<video:player_loc>#{e.call("https://www.youtube.com/embed/#{s.video_id}")}</video:player_loc>"
        <<~URL
          <url><loc>#{e.call(loc)}</loc><lastmod>#{(s.updated_at || s.created_at || Time.zone.now).iso8601}</lastmod>
          <video:video>#{poster ? "<video:thumbnail_loc>#{e.call(poster)}</video:thumbnail_loc>" : ""}<video:title>#{e.call(title)}</video:title><video:description>#{e.call(desc)}</video:description>#{media}<video:publication_date>#{(s.created_at || Time.zone.now).iso8601}</video:publication_date><video:view_count>#{s.views.to_i}</video:view_count><video:family_friendly>yes</video:family_friendly></video:video></url>
        URL
      end.join
      xml = %(<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:video="http://www.google.com/schemas/sitemap-video/1.1">\n<url><loc>#{e.call(base)}/shorts/browse</loc></url>\n#{urls}</urlset>\n)
      response.headers["Cache-Control"] = "public, max-age=3600"
      render xml: xml
    end
  end
end
