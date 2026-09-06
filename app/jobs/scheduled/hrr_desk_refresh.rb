# frozen_string_literal: true
# v0.9.0 — the refresh desk: on hrr_desk_refresh_weekdays at hrr_desk_refresh_hour_utc,
# up to 3 threads that already earn search clicks get a dated, sourced update.
module Jobs
  class HrrDeskRefresh < ::Jobs::Scheduled
    every 1.hour

    def execute(_args)
      return unless SiteSetting.hrr_desk_enabled && SiteSetting.hrr_desk_refresh_enabled
      return unless ::DiscourseShorts::Desk::Ai.enabled?
      now = Time.now.utc
      days = SiteSetting.hrr_desk_refresh_weekdays.to_s.split("|").map(&:to_i)
      return unless days.include?(now.wday) && now.hour >= SiteSetting.hrr_desk_refresh_hour_utc.to_i
      return if ::DiscourseShorts::Desk::Forum.done_today?("refresh")
      res = ::DiscourseShorts::Desk::Writer.refresh_desk!(max: 3)
      return unless res.is_a?(Array)
      ::DiscourseShorts::Desk::Forum.mark_today!("refresh")
      lines = res.map { |r| r[:url] ? "updated #{r[:url]}" : "skipped #{r[:topic_id]} \"#{r[:title].to_s[0, 60]}\": #{r[:skipped] || r[:error]}" }
      ::DiscourseShorts::Desk::Forum.log!("refresh desk", lines.presence || ["nothing to refresh"])
    rescue StandardError => e
      Rails.logger.warn("[hrr-desk] refresh desk failed: #{e.class} #{e.message}")
    end
  end
end
