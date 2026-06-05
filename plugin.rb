# frozen_string_literal: true
# name: discourse-shorts
# about: Short-form video library for the community feed. Server-stored YouTube short IDs with moderation, member submissions, persisted like/dislike + watch metrics, and scheduled auto-ingest from the YouTube Data API.
# version: 0.1.1
# authors: LF Builders

enabled_site_setting :shorts_enabled

after_initialize do
  module ::DiscourseShorts
    PLUGIN_NAME = "discourse-shorts"
  end

  require_relative "lib/discourse_shorts/youtube"
  require_relative "lib/discourse_shorts/seeder"

  # Seed the starter library once (idempotent; flag-guarded so admin deletes stick).
  begin
    if ActiveRecord::Base.connection.table_exists?("discourse_shorts")
      ::DiscourseShorts::Seeder.run!
    end
  rescue StandardError => e
    Rails.logger.warn("[discourse-shorts] seed on boot skipped: #{e.class} #{e.message}")
  end

  # NOTE: no route constraint class here -- AdminShortsController < Admin::AdminController
  # already enforces admin access. (A bogus constraint silently drops the whole block.)
  # Admin routes live under /shorts/admin/* to avoid colliding with core's
  # /admin/plugins/:id endpoint.
  Discourse::Application.routes.append do
    get    "/shorts"             => "discourse_shorts/shorts#index"
    post   "/shorts"             => "discourse_shorts/shorts#submit"
    post   "/shorts/:id/react"   => "discourse_shorts/shorts#react"
    post   "/shorts/:id/watch"   => "discourse_shorts/shorts#watch"
    get    "/shorts/admin/list"  => "discourse_shorts/admin_shorts#index"
    put    "/shorts/admin/:id"   => "discourse_shorts/admin_shorts#update"
    delete "/shorts/admin/:id"   => "discourse_shorts/admin_shorts#destroy"
  end
end
