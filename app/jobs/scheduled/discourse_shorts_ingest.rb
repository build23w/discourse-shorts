# frozen_string_literal: true
module Jobs
  class DiscourseShortsIngest < ::Jobs::Scheduled
    every 6.hours

    # v0.3.2: knobs moved to site settings (config/settings.yml) —
    # shorts_ingest_per_run, shorts_recycle_enabled, shorts_recycle_min_keep,
    # shorts_recycle_max_per_run, shorts_recycle_grace_hours. Clamped here so
    # a bad value can never mass-purge the library.
    def new_per_run
      (SiteSetting.shorts_ingest_per_run.to_i rescue 24).clamp(0, 200)
    end

    def min_keep
      (SiteSetting.shorts_recycle_min_keep.to_i rescue 100).clamp(0, 100_000)
    end

    def prune_max
      (SiteSetting.shorts_recycle_max_per_run.to_i rescue 24).clamp(0, 500)
    end

    def grace_hours
      (SiteSetting.shorts_recycle_grace_hours.to_i rescue 48).clamp(1, 8760)
    end

    def execute(_args)
      return unless SiteSetting.shorts_enabled && SiteSetting.shorts_ingest_enabled
      return if SiteSetting.shorts_youtube_api_key.blank?

      cap   = SiteSetting.shorts_max_library.to_i
      model = ::DiscourseShorts::Short

      recycle!(model, cap) if cap.positive? && SiteSetting.shorts_recycle_enabled
      ingest_new!(model)
    end

    private

    # Keep the library fresh WITHOUT ever wiping it. Only recycles auto-INGESTED
    # shorts that are genuinely dead (no comments, net likes <= 0). NEVER touches
    # locally uploaded (source="owned"), member submissions, seeded, or manual
    # shorts, never anything people engaged with, caps deletions per run, and
    # always leaves at least shorts_recycle_min_keep in the library.
    def recycle!(model, cap)
      approved = model.where(status: "approved").count
      overflow = approved + new_per_run - cap
      return if overflow <= 0

      max_del = [overflow, prune_max, approved - min_keep].min
      return if max_del <= 0

      # ANY interaction makes a short permanent: a like, dislike, comment, or share
      # disqualifies it forever. Only never-touched, auto-ingested shorts older
      # than the 48h grace window are eligible -- so fresh shorts get shuffled in
      # rotation for two days before they can ever be replaced.
      ids = model.where(status: "approved", source: "ingest")
                 .where(likes: 0, dislikes: 0, comment_count: 0)
                 .where("COALESCE(shares,0) = 0")
                 .where("created_at < ?", grace_hours.hours.ago)
                 .order(Arel.sql("views ASC, watch_seconds ASC, created_at ASC"))
                 .limit(max_del).pluck(:id)
      return if ids.empty?

      ::DiscourseShorts::Reaction.where(short_id: ids).delete_all
      model.where(id: ids).delete_all
      Rails.logger.info("[discourse-shorts] recycled #{ids.size} dead ingested shorts (kept #{approved - ids.size})")
    end

    def ingest_new!(model)
      terms = SiteSetting.shorts_ingest_terms.to_s.split("|").map(&:strip).reject(&:blank?)
      added = 0
      terms.shuffle.each do |term|
        break if added >= new_per_run
        found = ::DiscourseShorts::Youtube.search(term, max: 10)
        # v0.8.2: one videos.list call per term gives real descriptions for the
        # landing pages (the search result only carries a truncated one).
        details = ::DiscourseShorts::Youtube.details(found.reject { |v| model.exists?(video_id: v) })
        found.each do |vid|
          break if added >= new_per_run
          next if vid.blank? || model.exists?(video_id: vid)
          meta = ::DiscourseShorts::Youtube.oembed(vid)
          next if meta.nil?
          begin
            dt = details[vid] || {}
            model.create!(
              video_id: vid, provider: "youtube",
              title: meta["title"].to_s[0, 160],
              description: ::DiscourseShorts::Youtube.clean_description(dt["description"]).presence,
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
