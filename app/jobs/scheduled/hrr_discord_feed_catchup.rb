# frozen_string_literal: true
# v0.9.0 — hourly safety net behind the topic_created hook: any topic newer than the
# watermark that never reached Discord gets posted now.
module Jobs
  class HrrDiscordFeedCatchup < ::Jobs::Scheduled
    every 1.hour

    def execute(_args)
      return unless SiteSetting.hrr_discord_feed_enabled
      res = ::DiscourseShorts::Desk::Discord.feed_catchup!
      Rails.logger.info("[hrr-desk] discord feed catch-up: #{res.inspect[0, 200]}")
    rescue StandardError => e
      Rails.logger.warn("[hrr-desk] discord feed catch-up failed: #{e.class} #{e.message}")
    end
  end
end
