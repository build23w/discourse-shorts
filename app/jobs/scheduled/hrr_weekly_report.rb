# frozen_string_literal: true
# v0.9.0 — Monday 13:xx UTC: the growth report against the 2026-08-31 baseline, into the desk log topic.
module Jobs
  class HrrWeeklyReport < ::Jobs::Scheduled
    every 1.hour

    def execute(_args)
      return unless SiteSetting.hrr_desk_weekly_report_enabled
      now = Time.now.utc
      return unless now.wday == 1 && now.hour >= 13
      return unless ::DiscourseShorts::Desk::Forum.once_per_day?("weekly-report")
      ::DiscourseShorts::Desk::Forum.log!("weekly growth report", ::DiscourseShorts::Desk::Growth.build)
    rescue StandardError => e
      Rails.logger.warn("[hrr-desk] weekly report failed: #{e.class} #{e.message}")
    end
  end
end
