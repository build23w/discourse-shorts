# frozen_string_literal: true
# v0.9.0 — hourly: port staff-pinned #ask-the-pros threads to the forum, with consent.
module Jobs
  class HrrDiscordPort < ::Jobs::Scheduled
    every 1.hour

    def execute(_args)
      return unless SiteSetting.hrr_discord_port_enabled && ::DiscourseShorts::Desk::Discord.bot?
      res = ::DiscourseShorts::Desk::Discord.port!
      moved = Array(res[:log])
      ::DiscourseShorts::Desk::Forum.log!("discord port", moved) if moved.any? || res[:error]
      Rails.logger.info("[hrr-desk] discord port: #{res.inspect[0, 300]}")
    rescue StandardError => e
      Rails.logger.warn("[hrr-desk] discord port failed: #{e.class} #{e.message}")
    end
  end
end
