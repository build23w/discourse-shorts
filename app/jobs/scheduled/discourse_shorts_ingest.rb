# frozen_string_literal: true
module Jobs
  class DiscourseShortsIngest < ::Jobs::Scheduled
    every 6.hours

    def execute(_args)
      return unless SiteSetting.shorts_enabled && SiteSetting.shorts_ingest_enabled
      return if SiteSetting.shorts_youtube_api_key.blank?

      cap = SiteSetting.shorts_max_library.to_i
      return if cap.positive? && ::DiscourseShorts::Short.where(status: "approved").count >= cap

      terms = SiteSetting.shorts_ingest_terms.to_s.split("|").map(&:strip).reject(&:blank?)
      added = 0
      terms.each do |term|
        ::DiscourseShorts::Youtube.search(term, max: 10).each do |vid|
          next if vid.blank? || ::DiscourseShorts::Short.exists?(video_id: vid)
          meta = ::DiscourseShorts::Youtube.oembed(vid)
          next if meta.nil?
          begin
            ::DiscourseShorts::Short.create!(
              video_id: vid, provider: "youtube",
              title: meta["title"].to_s[0, 160],
              tags: term.gsub(/\s+/, "-"),
              status: "approved", source: "ingest"
            )
            added += 1
          rescue StandardError => e
            Rails.logger.warn("[discourse-shorts] ingest #{vid}: #{e.class} #{e.message}")
          end
        end
      end
      Rails.logger.info("[discourse-shorts] ingest added #{added} shorts") if added.positive?
    end
  end
end
