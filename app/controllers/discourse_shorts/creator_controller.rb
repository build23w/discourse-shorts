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
        description: params[:description].to_s.strip[0, 600].presence,
        tags: Array(params[:tags]).join(",")[0, 255],
        submitted_by_id: current_user.id,
        status: auto_approve? ? "approved" : "pending",
        source: "creator"
      )
      # v0.6.0 creator ladder: a pending upload pings the moderators (one PM per
      # upload, from system) so the review queue never sits unseen.
      notify_moderators(s) if s.status == "pending"
      # CLOUDFLARED MODE: mirror the bytes into R2 (async, fire-and-forget) so
      # the read-time CDN remap covers this new short. On any failure the short
      # keeps streaming from the upload store via the *_origin fallback.
      if ::DiscourseShorts::Media.mirror_uploads?
        ::Jobs.enqueue(
          :discourse_shorts_mirror_media,
          upload_id: upload.id,
          poster_upload_id: poster&.id,
        )
      end
      render json: { ok: true, status: s.status, video_id: s.video_id, id: s.id }
    end

    # PATCH /shorts/creator/:id.json — v0.8.0: creators edit the title/description/
    # tags of their OWN shorts (staff: any). Text only — media and status are not
    # editable here. Approved shorts stay approved: a description is metadata, not
    # a new video, and the landing page escapes everything it prints.
    def update
      s = Short.find_by(id: params[:id]) or raise Discourse::NotFound
      raise Discourse::InvalidAccess unless current_user.staff? || s.submitted_by_id == current_user.id
      attrs = {}
      attrs[:title] = params[:title].to_s.strip[0, 160] if params.key?(:title) && params[:title].to_s.strip.present?
      attrs[:description] = params[:description].to_s.strip[0, 600].presence if params.key?(:description)
      attrs[:tags] = Array(params[:tags]).map { |t| t.to_s.strip }.reject(&:blank?).join(",")[0, 255] if params.key?(:tags)
      s.update!(attrs) if attrs.any?
      render json: { ok: true, id: s.id, title: s.title, description: s.try(:description), tags: s.tag_list }
    end

    # DELETE /shorts/creator/:id.json — creators manage their OWN library.
    # Row only (reactions/topic untouched, same as AdminShortsController#destroy).
    # Staff may delete any.
    def destroy
      s = Short.find_by(id: params[:id])
      raise Discourse::NotFound if s.nil?
      raise Discourse::InvalidAccess unless current_user.staff? || s.submitted_by_id == current_user.id
      s.destroy!
      render json: { ok: true }
    end

    def mine
      ensure_creator!
      rows = Short.where(submitted_by_id: current_user.id).order(id: :desc).limit(50)
      render json: { shorts: rows.map { |s| {
        id: s.id, video_id: s.video_id, title: s.title, description: s.try(:description), status: s.status,
        provider: s.provider, poster_url: ::DiscourseShorts::Media.cdn(s.poster_url), created_at: (s.created_at.to_i rescue nil),
        views: s.views.to_i, likes: s.likes.to_i, comment_count: s.comment_count.to_i,
        shares: s.try(:shares).to_i
      } } }
    end

    private

    # v0.6.0 creator ladder: uploads by members at or above
    # shorts_auto_approve_trust_level go live instantly (same rule the YouTube
    # link submissions already follow); everyone else lands in the review queue.
    def auto_approve?
      return true if current_user.staff?
      current_user.trust_level >= SiteSetting.shorts_auto_approve_trust_level.to_i
    end

    def notify_moderators(s)
      title = "Short awaiting review: #{s.title.to_s[0, 60]}"
      raw = <<~MD
        @#{current_user.username} (trust level #{current_user.trust_level}) uploaded a short that needs a look.

        **#{s.title}**
        #{s.video_url}

        Open the feed and tap **🛡 Review** in the Shorts rail to approve or reject it.
      MD
      ::PostCreator.new(
        ::Discourse.system_user,
        title: title,
        raw: raw,
        archetype: ::Archetype.private_message,
        target_group_names: ["moderators"],
        skip_validations: true,
      ).create
    rescue StandardError => e
      Rails.logger.warn("discourse-shorts: moderator notify failed: #{e.class}: #{e.message}")
    end

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
