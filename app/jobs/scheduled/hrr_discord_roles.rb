# frozen_string_literal: true
# v0.9.0 — daily (09:xx UTC): mirror forum standing onto the Reno Insider / Verified Reviewer roles.
module Jobs
  class HrrDiscordRoles < ::Jobs::Scheduled
    every 1.hour

    def execute(_args)
      return unless SiteSetting.hrr_discord_roles_enabled && ::DiscourseShorts::Desk::Discord.bot?
      return unless Time.now.utc.hour >= 9
      return unless ::DiscourseShorts::Desk::Forum.once_per_day?("discord-roles")
      res = ::DiscourseShorts::Desk::Discord.roles!
      lines = ["#{res[:claims]} claims, #{res[:granted]} grant(s)"]
      lines << "not in server: #{res[:missing].join(', ')}" if res[:missing].present?
      lines << "duplicate handles skipped: #{res[:duplicate_handles].join(', ')}" if res[:duplicate_handles].present?
      lines = [res[:skipped] || res[:error]] if res[:skipped] || res[:error]
      ::DiscourseShorts::Desk::Forum.log!("discord roles", lines)
    rescue StandardError => e
      Rails.logger.warn("[hrr-desk] discord roles failed: #{e.class} #{e.message}")
    end
  end
end
