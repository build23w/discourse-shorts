# frozen_string_literal: true
module DiscourseShorts
  class ShortsController < ::ApplicationController
    requires_plugin ::DiscourseShorts::PLUGIN_NAME
    before_action :ensure_enabled
    before_action :ensure_logged_in, only: %i[submit react watch]
    skip_before_action :check_xhr, only: %i[index]

    def index
      limit = params[:limit].to_i
      limit = 200 if limit <= 0 || limit > 500
      rows = Short.where(status: "approved").order(Arel.sql("(likes - dislikes) DESC, id DESC")).limit(limit)
      mine = current_user ? Reaction.where(user_id: current_user.id, short_id: rows.map(&:id)).pluck(:short_id, :direction).to_h : {}
      render json: { shorts: rows.map { |s| serialize_short(s, mine[s.id]) } }
    end

    def submit
      raise Discourse::InvalidAccess unless user_can_submit?(current_user)
      vid = Youtube.extract_id(params[:url].presence || params[:video_id])
      raise Discourse::InvalidParameters.new(:url) if vid.blank?
      meta = Youtube.oembed(vid)
      raise Discourse::InvalidParameters.new(:url) if meta.nil? # not found / not embeddable

      if (existing = Short.find_by(video_id: vid))
        return render(json: { ok: true, duplicate: true, short: serialize_short(existing) })
      end

      auto = current_user.staff? || current_user.trust_level >= SiteSetting.shorts_auto_approve_trust_level.to_i
      s = Short.create!(
        video_id: vid, provider: "youtube",
        title: (params[:title].presence || meta["title"]).to_s[0, 160],
        tags: Array(params[:tags]).join(",")[0, 255],
        submitted_by_id: current_user.id,
        status: auto ? "approved" : "pending",
        source: "submission"
      )
      render json: { ok: true, status: s.status, short: serialize_short(s) }
    end

    def react
      s = Short.find_by(id: params[:id]) or raise Discourse::NotFound
      dir = params[:dir].to_s
      r = Reaction.find_or_initialize_by(short_id: s.id, user_id: current_user.id)
      Short.transaction do
        case r.direction
        when "up" then s.likes = [s.likes - 1, 0].max
        when "down" then s.dislikes = [s.dislikes - 1, 0].max
        end
        case dir
        when "up" then s.likes += 1; r.direction = "up"
        when "down" then s.dislikes += 1; r.direction = "down"
        else r.direction = nil
        end
        s.save!
        r.direction.nil? ? (r.destroy if r.persisted?) : r.save!
      end
      render json: { ok: true, likes: s.likes, dislikes: s.dislikes, my: r.direction }
    end

    def watch
      s = Short.find_by(id: params[:id]) or raise Discourse::NotFound
      secs = params[:seconds].to_i
      secs = 0 if secs.negative? || secs > 3600
      Short.where(id: s.id).update_all(["views = views + 1, watch_seconds = watch_seconds + ?", secs])
      render json: { ok: true }
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.shorts_enabled
    end

    def user_can_submit?(user)
      return true if user.staff?                                   # staff can ALWAYS upload
      return false unless SiteSetting.shorts_allow_member_submissions
      user.trust_level >= SiteSetting.shorts_min_submit_trust_level.to_i
    end

    def serialize_short(s, my = nil)
      { id: s.id, video_id: s.video_id, title: s.title, tags: s.tag_list,
        likes: s.likes, dislikes: s.dislikes, views: s.views, my_reaction: my }
    end
  end
end
