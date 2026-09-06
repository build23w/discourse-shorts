# frozen_string_literal: true
# v0.9.0 — Monday 12:00 UTC: propose the next Shirt Lab batch into the private Staff topic.
module Jobs
  class HrrShirtIdeas < ::Jobs::Scheduled
    every 1.hour

    def execute(_args)
      return unless SiteSetting.hrr_shirt_ideas_enabled && ::DiscourseShorts::Desk::Ai.enabled?
      now = Time.now.utc
      return unless now.wday == 1 && now.hour >= 12
      return unless ::DiscourseShorts::Desk::Forum.once_per_day?("shirt-ideas")
      res = ::DiscourseShorts::Desk::ShirtLab.ideas!
      ::DiscourseShorts::Desk::Forum.log!("shirt ideas", [res[:skipped] || res[:error] || "topic #{res[:topic_id]}: #{Array(res[:ideas]).join(', ')}"])
    rescue StandardError => e
      Rails.logger.warn("[hrr-desk] shirt ideas failed: #{e.class} #{e.message}")
    end
  end
end
