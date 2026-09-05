# frozen_string_literal: true
# v0.8.2 — backfill descriptions for the ~2,000 YouTube shorts ingested before
# the description column existed. 100 shorts per run (2 videos.list calls, 2 quota
# units), every 20 minutes, so the whole library is described within ~7 hours of
# the first boot and the job is a no-op afterwards. NULL = not yet looked up; an
# empty string marks "looked up, YouTube had nothing printable" so it is never
# re-fetched. Skips owned/creator uploads (their descriptions are human-written).
module Jobs
  class DiscourseShortsBackfillDescriptions < ::Jobs::Scheduled
    every 20.minutes

    def execute(_args)
      return unless SiteSetting.shorts_enabled
      return if SiteSetting.shorts_youtube_api_key.to_s.blank?
      model = ::DiscourseShorts::Short
      return unless model.column_names.include?("description")
      rows = model.where(provider: "youtube", description: nil).order(views: :desc).limit(100).to_a
      return if rows.empty?
      rows.each_slice(50) do |batch|
        details = ::DiscourseShorts::Youtube.details(batch.map(&:video_id))
        batch.each do |s|
          d = ::DiscourseShorts::Youtube.clean_description((details[s.video_id] || {})["description"])
          s.update_columns(description: d.to_s) # "" = looked up, nothing usable
        end
      end
      Rails.logger.info("[discourse-shorts] backfilled descriptions for #{rows.size} shorts")
    rescue StandardError => e
      Rails.logger.warn("[discourse-shorts] description backfill failed: #{e.message}")
    end
  end
end
