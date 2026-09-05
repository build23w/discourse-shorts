# frozen_string_literal: true
# name: discourse-shorts
# about: Short-form video library for the community feed. Server-stored YouTube short IDs + LF-produced uploaded videos, with moderation, member submissions, persisted like/dislike + watch metrics, $RENO payouts, a comment->topic system, and scheduled auto-ingest from the YouTube Data API.
# version: 0.8.2
# authors: LF Builders

enabled_site_setting :shorts_enabled

register_asset "stylesheets/shorts-overrides.scss"

after_initialize do

  # Keep Short.comment_count in sync with NATIVE topic replies too (not just
  # overlay-posted comments). Badge accuracy + recycler permanence both depend
  # on this column.
  on(:post_created) do |post|
    begin
      if post.post_number.to_i > 1 && post.topic_id
        sh = ::DiscourseShorts::Short.find_by(topic_id: post.topic_id)
        if sh
          pc = post.topic&.posts_count || ::Topic.where(id: post.topic_id).pick(:posts_count) || 1
          sh.update_columns(comment_count: [pc - 1, 0].max)
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[discourse-shorts] comment_count sync failed: #{e.message}")
    end
  end
  module ::DiscourseShorts
    PLUGIN_NAME = "discourse-shorts"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseShorts
    end
  end

  # Explicit load order (mirrors the proven pattern on this Discourse build):
  # models + lib BEFORE controllers + seeders. Do NOT require_relative lib/app
  # files -- that fights Zeitwerk and silently aborts the rest of after_initialize.
  load File.expand_path("../app/models/discourse_shorts/short.rb", __FILE__)
  load File.expand_path("../app/models/discourse_shorts/reaction.rb", __FILE__)
  load File.expand_path("../app/models/discourse_shorts/reaction_reward_claim.rb", __FILE__)
  load File.expand_path("../app/models/discourse_shorts/progress.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/media.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/journey.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/recommender.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/youtube.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/discussions.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/crawler_links.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/seeder.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/owned_seeder.rb", __FILE__)
  load File.expand_path("../app/controllers/discourse_shorts/shorts_controller.rb", __FILE__)
  load File.expand_path("../app/controllers/discourse_shorts/admin_shorts_controller.rb", __FILE__)
  load File.expand_path("../app/controllers/discourse_shorts/creator_controller.rb", __FILE__)
  load File.expand_path("../app/controllers/discourse_shorts/seo_controller.rb", __FILE__)
  load File.expand_path("../app/jobs/scheduled/discourse_shorts_ingest.rb", __FILE__)
  load File.expand_path("../app/jobs/regular/discourse_shorts_mirror_media.rb", __FILE__)
  load File.expand_path("../app/jobs/scheduled/discourse_shorts_backfill_descriptions.rb", __FILE__)

  # v0.8.1 — internal links from every topic's crawler view to same-trade shorts
  register_html_builder("server:topic-show-after-posts-crawler") do |ctx|
    ::DiscourseShorts::CrawlerLinks.html_for(ctx)
  end

  # Routes use explicit .json (bare paths get caught by Discourse's Ember route).
  # Admin routes live under /shorts/admin/* (NOT /admin/plugins/* which the core
  # plugin-show route catches first). No route constraint -- AdminShortsController
  # < Admin::AdminController already enforces admin.
  Discourse::Application.routes.append do
    get    "/shorts"               => "discourse_shorts/shorts#index"
    get    "/shorts.json"          => "discourse_shorts/shorts#index"
    post   "/shorts"               => "discourse_shorts/shorts#submit"
    post   "/shorts.json"          => "discourse_shorts/shorts#submit"
    post   "/shorts/:id/react"     => "discourse_shorts/shorts#react"
    post   "/shorts/:id/watch"     => "discourse_shorts/shorts#watch"
    post   "/shorts/watch_batch.json" => "discourse_shorts/shorts#watch_batch"
    # v0.7.0: the landing page is the same for humans and crawlers (no 302, no
    # UA branching) — a real, indexable page per short + a browse index + a
    # video sitemap. share_page stays defined for reference but is unrouted.
    get    "/shorts/v/:video_id"     => "discourse_shorts/seo#landing", constraints: { video_id: %r{[\w\-]+} }, format: false
    get    "/shorts/browse"          => "discourse_shorts/seo#browse", format: false
    get    "/shorts/sitemap.xml"     => "discourse_shorts/seo#sitemap", format: false
    post   "/shorts/:id/share"     => "discourse_shorts/shorts#share"
    post   "/shorts/:id/share.json" => "discourse_shorts/shorts#share"
    get    "/shorts/:id/comments"      => "discourse_shorts/shorts#comments_index"
    get    "/shorts/:id/comments.json" => "discourse_shorts/shorts#comments_index"
    post   "/shorts/:id/comments"      => "discourse_shorts/shorts#comments_create"
    post   "/shorts/:id/comments.json" => "discourse_shorts/shorts#comments_create"
    post   "/shorts/creator/submit.json" => "discourse_shorts/creator#submit"
    get    "/shorts/creator/mine.json"    => "discourse_shorts/creator#mine"
    patch  "/shorts/creator/:id"          => "discourse_shorts/creator#update"
    patch  "/shorts/creator/:id.json"     => "discourse_shorts/creator#update"
    put    "/shorts/creator/:id.json"     => "discourse_shorts/creator#update"
    delete "/shorts/creator/:id"          => "discourse_shorts/creator#destroy"
    delete "/shorts/creator/:id.json"     => "discourse_shorts/creator#destroy"
    get    "/shorts/admin/list.json" => "discourse_shorts/admin_shorts#index"
    put    "/shorts/admin/:id"     => "discourse_shorts/admin_shorts#update"
    delete "/shorts/admin/:id"     => "discourse_shorts/admin_shorts#destroy"
  end

  # Seed the starter library + LF-owned uploaded videos once (idempotent;
  # flag-guarded so admin deletes stick).
  begin
    if ActiveRecord::Base.connection.table_exists?("discourse_shorts")
      ::DiscourseShorts::Seeder.run!
      if ActiveRecord::Base.connection.column_exists?("discourse_shorts", "video_url")
        ::DiscourseShorts::OwnedSeeder.run!
      end
    end
  rescue => e
    Rails.logger.warn("[discourse-shorts] seed on boot skipped: #{e.class} #{e.message}")
  end
end
