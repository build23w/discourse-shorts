# frozen_string_literal: true
# name: discourse-shorts
# about: Short-form video library for the community feed. Server-stored YouTube short IDs with moderation, member submissions, persisted like/dislike + watch metrics, and scheduled auto-ingest from the YouTube Data API.
# version: 0.1.0
# authors: LF Builders

enabled_site_setting :shorts_enabled

after_initialize do
  module ::DiscourseShorts
    PLUGIN_NAME = "discourse-shorts"
  end

  require_relative "lib/discourse_shorts/youtube"

  Discourse::Application.routes.append do
    get    "/shorts"            => "discourse_shorts/shorts#index"
    post   "/shorts"            => "discourse_shorts/shorts#submit"
    post   "/shorts/:id/react"  => "discourse_shorts/shorts#react"
    post   "/shorts/:id/watch"  => "discourse_shorts/shorts#watch"
    get    "/admin/plugins/shorts"      => "discourse_shorts/admin_shorts#index",   constraints: StaffConstraint.new
    put    "/admin/plugins/shorts/:id"  => "discourse_shorts/admin_shorts#update",  constraints: StaffConstraint.new
    delete "/admin/plugins/shorts/:id"  => "discourse_shorts/admin_shorts#destroy", constraints: StaffConstraint.new
  end
end
