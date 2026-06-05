# frozen_string_literal: true
# name: discourse-shorts
# about: Short-form video library for the community feed. Server-stored YouTube short IDs + LF-produced uploaded videos, with moderation, member submissions, persisted like/dislike + watch metrics, $RENO payouts, a comment->topic system, and scheduled auto-ingest from the YouTube Data API.
# version: 0.2.1
# authors: LF Builders

enabled_site_setting :shorts_enabled

after_initialize do
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
  load File.expand_path("../lib/discourse_shorts/youtube.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/discussions.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/seeder.rb", __FILE__)
  load File.expand_path("../lib/discourse_shorts/owned_seeder.rb", __FILE__)
  load File.expand_path("../app/controllers/discourse_shorts/shorts_controller.rb", __FILE__)
  load File.expand_path("../app/controllers/discourse_shorts/admin_shorts_controller.rb", __FILE__)
  load File.expand_path("../app/jobs/scheduled/discourse_shorts_ingest.rb", __FILE__)

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
    get    "/shorts/:id/comments"      => "discourse_shorts/shorts#comments_index"
    get    "/shorts/:id/comments.json" => "discourse_shorts/shorts#comments_index"
    post   "/shorts/:id/comments"      => "discourse_shorts/shorts#comments_create"
    post   "/shorts/:id/comments.json" => "discourse_shorts/shorts#comments_create"
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
