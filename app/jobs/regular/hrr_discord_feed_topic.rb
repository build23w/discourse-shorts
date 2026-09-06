# frozen_string_literal: true
# v0.9.0 — push one freshly created topic to the routed Discord webhook (enqueued
# from the topic_created hook with a short delay so the topic is fully saved).
module Jobs
  class HrrDiscordFeedTopic < ::Jobs::Base
    sidekiq_options retry: false

    def execute(args)
      return unless SiteSetting.hrr_discord_feed_enabled
      topic = ::Topic.find_by(id: args[:topic_id])
      return unless topic
      return if topic.id <= ::DiscourseShorts::Desk::Discord.watermark
      ::DiscourseShorts::Desk::Discord.feed_topic!(topic)
    rescue StandardError => e
      Rails.logger.warn("[hrr-desk] discord feed topic failed: #{e.class} #{e.message}")
    end
  end
end
