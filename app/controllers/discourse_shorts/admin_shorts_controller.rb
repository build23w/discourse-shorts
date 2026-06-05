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
      render json: { ok: true, status: s.status }
    end

    def destroy
      Short.where(id: params[:id]).destroy_all
      render json: { ok: true }
    end

    private

    def serialize(s)
      { id: s.id, video_id: s.video_id, title: s.title, tags: s.tag_list,
        status: s.status, source: s.source, submitted_by_id: s.submitted_by_id }
    end
  end
end
