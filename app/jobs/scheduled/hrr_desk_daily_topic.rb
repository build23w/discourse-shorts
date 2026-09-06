# frozen_string_literal: true
# v0.9.0 — one researched topic a day as the poster account, at hrr_desk_daily_topic_hour_utc.
# Runs hourly, acts once per UTC day (PluginStore marker), never more than one topic.
module Jobs
  class HrrDeskDailyTopic < ::Jobs::Scheduled
    every 1.hour

    def execute(_args)
      return unless SiteSetting.hrr_desk_enabled && SiteSetting.hrr_desk_daily_topic_enabled
      return unless ::DiscourseShorts::Desk::Ai.enabled?
      return unless Time.now.utc.hour >= SiteSetting.hrr_desk_daily_topic_hour_utc.to_i
      return if ::DiscourseShorts::Desk::Forum.done_today?("daily-topic")
      res = ::DiscourseShorts::Desk::Writer.daily_topic!
      # a transient failure (model down, budget) is retried next hour; a post or a deliberate skip closes the day
      ::DiscourseShorts::Desk::Forum.mark_today!("daily-topic") if res[:url] || res[:skipped]
      ::DiscourseShorts::Desk::Forum.log!("daily topic", [res[:url] || res[:skipped] || res[:error], res[:title], res[:sources]&.join(" "), res[:index] && "faq index: #{res[:index]}"])
    rescue StandardError => e
      Rails.logger.warn("[hrr-desk] daily topic failed: #{e.class} #{e.message}")
    end
  end
end
