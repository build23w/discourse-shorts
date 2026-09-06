# frozen_string_literal: true
# v0.9.0 — refresh the Shirt Lab carousel feed from shirtlab.lol every 6 hours.
module Jobs
  class HrrShirtFeed < ::Jobs::Scheduled
    every 6.hours

    def execute(_args)
      return unless SiteSetting.hrr_shirt_feed_enabled
      res = ::DiscourseShorts::Desk::ShirtLab.feed!
      Rails.logger.info("[hrr-desk] shirt feed: #{res.inspect[0, 300]}")
    rescue StandardError => e
      Rails.logger.warn("[hrr-desk] shirt feed failed: #{e.class} #{e.message}")
    end
  end
end
