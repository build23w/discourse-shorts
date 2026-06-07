# frozen_string_literal: true
module DiscourseShorts
  class CreatorController < ::ApplicationController
    requires_plugin ::DiscourseShorts::PLUGIN_NAME
    requires_login

    ALLOWED_EXTS = %w[mp4 webm mov m4v].freeze

    def submit
      ensure_creator!
      RateLimiter.new(current_user, "shorts_creator_submit", SiteSetting.shorts_creator_daily_cap, 1.day).performed!

      upload = ::Upload.find_by(id: params[:upload_id].to_i)
      raise Discourse::InvalidParameters.new(:upload_id) if upload.nil?
      raise Discourse::InvalidAccess if upload.user_id != current_user.id && !current_user.staff?
      ext = upload.extension.to_s.downcase
      raise Discourse::InvalidParameters.new(:upload_id) unless ALLOWED_EXTS.include?(ext)
      max_bytes = SiteSetting.shorts_creator_max_mb.to_i * 1024 * 1024
      raise Discourse::InvalidParameters.new(:too_large) if upload.filesize.to_i > max_bytes

      # Duration guard: trust the client check, verify server-side when ffprobe exists.
      if (secs = probe_duration(upload)) && secs > SiteSetting.shorts_creator_max_seconds.to_i + 1
        raise Discourse::InvalidParameters.new(:too_long)
      end

      poster = params[:poster_upload_id].present? ? ::Upload.find_by(id: params[:poster_upload_id].to_i) : nil
      poster = nil if poster && poster.user_id != current_user.id && !current_user.staff?

      vid = "lfv-u#{current_user.id}-#{SecureRandom.hex(4)}"
      s = Short.create!(
        video_id: vid, provider: "upload",
        video_url: GlobalPath.full_cdn_url(upload.url),
        upload_ref: upload.id.to_s,
        poster_url: poster ? GlobalPath.full_cdn_url(poster.url) : nil,
        title: params[:title].to_s.strip[0, 160].presence || "My short",
        tags: Array(params[:tags]).join(",")[0, 255],
        submitted_by_id: current_user.id,
        status: current_user.staff? ? "approved" : "pending",
        source: "creator"
      )
      render json: { ok: true, status: s.status, video_id: s.video_id, id: s.id }
    end

    def mine
      ensure_creator!
      rows = Short.where(submitted_by_id: current_user.id).order(id: :desc).limit(50)
      render json: { shorts: rows.map { |s| {
        id: s.id, video_id: s.video_id, title: s.title, status: s.status,
        provider: s.provider, poster_url: s.poster_url, created_at: (s.created_at.to_i rescue nil),
        views: s.views.to_i, likes: s.likes.to_i, comment_count: s.comment_count.to_i,
        shares: s.try(:shares).to_i
      } } }
    end

    private

    def ensure_creator!
      return if current_user.staff?
      ids = SiteSetting.shorts_creator_groups.to_s.split("|").map(&:to_i).reject(&:zero?)
      raise Discourse::InvalidAccess if ids.empty?   # unset = staff-only until a group is picked
      raise Discourse::InvalidAccess unless ::GroupUser.where(user_id: current_user.id, group_id: ids).exists?
    end

    def probe_duration(upload)
      path = ::Discourse.store.path_for(upload)
      return nil if path.blank? || !File.exist?(path)
      out = Discourse::Utils.execute_command(
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", path
      )
      out.to_f
    rescue StandardError
      nil   # remote store / no ffprobe: client check + moderation queue are the guards
    end
  end
end
