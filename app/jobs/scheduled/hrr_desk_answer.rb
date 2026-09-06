# frozen_string_literal: true
# v0.9.0 — the answer desk: every 3 hours, at most hrr_desk_answer_max_per_run
# unanswered member threads get a sourced reply (or, for obvious promo, an unlist).
module Jobs
  class HrrDeskAnswer < ::Jobs::Scheduled
    every 3.hours

    def execute(_args)
      return unless SiteSetting.hrr_desk_enabled && SiteSetting.hrr_desk_answer_enabled
      return unless ::DiscourseShorts::Desk::Ai.enabled?
      res = ::DiscourseShorts::Desk::Writer.answer_desk!(max: SiteSetting.hrr_desk_answer_max_per_run.to_i)
      return unless res.is_a?(Array) && res.any?
      lines = res.map do |r|
        if r[:unlisted] then "unlisted #{r[:topic_id]} \"#{r[:title].to_s[0, 60]}\": #{r[:reason]}"
        elsif r[:url] then "replied (#{r[:kind]}) #{r[:url]}"
        else "skipped #{r[:topic_id]} \"#{r[:title].to_s[0, 60]}\": #{r[:skipped] || r[:error]}"
        end
      end
      ::DiscourseShorts::Desk::Forum.log!("answer desk", lines)
    rescue StandardError => e
      Rails.logger.warn("[hrr-desk] answer desk failed: #{e.class} #{e.message}")
    end
  end
end
