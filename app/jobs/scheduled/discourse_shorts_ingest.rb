# frozen_string_literal: true
module Jobs
  class DiscourseShortsIngest < ::Jobs::Scheduled
    every 6.hours

    NEW_PER_RUN = 24   # how many fresh shorts to pull each run

    def execute(_args)
      return unless SiteSetting.shorts_enabled && SiteSetting.shorts_ingest_enabled
      return if SiteSetting.shorts_youtube_api_key.blank?

      cap   = SiteSetting.shorts_max_library.to_i
      model = ::DiscourseShorts::Short

      # Keep the library FRESH: when at/over cap, recycle the worst-performing
      # INGESTED shorts (never owned/submission/manual/seed) to make room for new
      # ones. Worst = lowest net likes, then fewest views, then oldest.
      if cap.positive?
        approved = model.where(status: "approved").count
        overflow = approved + NEW_PER_RUN - cap
        if overflow.positive?
          ids = model.where(status: "approved", source: "ingest")
                     .order(Arel.sql("(likes - dislikes) ASC, views ASC, watch_seconds ASC, created_at ASC"))
                     .limit(overflow).pluck(:id)
          if ids.any?
            ::DiscourseShorts::Reaction.where(short_id: ids).delete_all
            model.where(id: ids).delete_all
            Rails.logger.info("[discourse-shorts] recycled #{ids.size} underperforming shorts")
          end
        end
      end

      terms = SiteSetting.shorts_ingest_terms.to_s.split("|").map(&:strip).reject(&:blank?)
      added = 0
      terms.shuffle.each do |term|
        break if added >= NEW_PER_RUN
        ::DiscourseShorts::Youtube.search(term, max: 10).each do |vid|
          break if added >= NEW_PER_RUN
          next if vid.blank? || model.exists?(video_id: vid)
          meta = ::DiscourseShorts::Youtube.oembed(vid)
          next if meta.nil?
          begin
            model.create!(
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
