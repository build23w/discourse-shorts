# frozen_string_literal: true
module Jobs
  class DiscourseShortsIngest < ::Jobs::Scheduled
    every 6.hours

    NEW_PER_RUN = 24      # fresh shorts pulled per run
    MIN_KEEP    = 100     # never let recycling shrink the library below this
    PRUNE_MAX   = 24      # hard cap on deletions per run (never a mass purge)
    GRACE_HOURS = 48      # a short must live this long before it can be recycled

    def execute(_args)
      return unless SiteSetting.shorts_enabled && SiteSetting.shorts_ingest_enabled
      return if SiteSetting.shorts_youtube_api_key.blank?

      cap   = SiteSetting.shorts_max_library.to_i
      model = ::DiscourseShorts::Short

      recycle!(model, cap) if cap.positive?
      ingest_new!(model)
    end

    private

    # Keep the library fresh WITHOUT ever wiping it. Only recycles auto-INGESTED
    # shorts that are genuinely dead (no comments, net likes <= 0). NEVER touches
    # locally uploaded (source="owned"), member submissions, seeded, or manual
    # shorts, never anything people engaged with, caps deletions per run, and
    # always leaves at least MIN_KEEP in the library.
    def recycle!(model, cap)
      approved = model.where(status: "approved").count
      overflow = approved + NEW_PER_RUN - cap
      return if overflow <= 0

      max_del = [overflow, PRUNE_MAX, approved - MIN_KEEP].min
      return if max_del <= 0

      # ANY interaction makes a short permanent: a like, dislike, comment, or share
      # disqualifies it forever. Only never-touched, auto-ingested shorts older
      # than the 48h grace window are eligible -- so fresh shorts get shuffled in
      # rotation for two days before they can ever be replaced.
      ids = model.where(status: "approved", source: "ingest")
                 .where(likes: 0, dislikes: 0, comment_count: 0)
                 .where("COALESCE(shares,0) = 0")
                 .where("created_at < ?", GRACE_HOURS.hours.ago)
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
