# frozen_string_literal: true
module DiscourseShorts
  class AdminShortsController < ::Admin::AdminController
    requires_plugin ::DiscourseShorts::PLUGIN_NAME

    def index
      render json: {
        pending: Short.where(status: "pending").order(id: :desc).limit(200).map { |s| serialize(s) },
        approved_count: Short.where(status: "approved").count,
        pending_count: Short.where(status: "pending").count
      }
    end

    def update
      s = Short.find(params[:id])
      st = params[:status].to_s
      s.update!(status: st) if %w[approved pending rejected].include?(st)
      # Allow swapping media URLs (e.g. replacing a non-faststart MP4 with a
      # remuxed copy). Admin-only; restricted to our own upload store so the
      # endpoint can't be pointed at arbitrary hosts.
      media = {}
      %i[video_url poster_url vp9_url].each do |k|
        nv = params[k].to_s
        next if nv.blank?
        ok = nv.start_with?("/uploads/", "//renovation-reviews.storage.googleapis.com/", "https://renovation-reviews.storage.googleapis.com/")
        # cloudflared mode: the configured media CDN is also one of "our own" hosts
        cf_base = SiteSetting.shorts_cloudflare_base_url.to_s.chomp("/")
        ok ||= cf_base.start_with?("https://") && nv.start_with?("#{cf_base}/")
        media[k] = nv if ok
      end
      s.update!(media) if media.any?
      render json: { ok: true, status: s.status, video_url: s.video_url, poster_url: s.poster_url }
    end

    def destroy
      Short.where(id: params[:id]).destroy_all
      render json: { ok: true }
    end

    private

    def serialize(s)
      submitter = s.submitted_by_id ? ::User.find_by(id: s.submitted_by_id) : nil
      { id: s.id, video_id: s.video_id, title: s.title, description: s.try(:description), tags: s.tag_list,
        status: s.status, source: s.source, submitted_by_id: s.submitted_by_id,
        submitted_by: submitter&.username,
        provider: s.provider, video_url: s.video_url, vp9_url: s.try(:vp9_url),
        poster_url: s.poster_url, created_at: (s.created_at.to_i rescue nil) }
    end
  end
end
