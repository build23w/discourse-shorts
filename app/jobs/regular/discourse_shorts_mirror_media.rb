# frozen_string_literal: true
module Jobs
  # CLOUDFLARED MODE: asynchronously mirror a creator-submitted video (and its
  # poster) from the Discourse upload store into the Cloudflare R2 bucket so
  # the read-time CDN remap can serve it. Fire-and-forget: any failure is
  # logged and the short keeps working off the origin store URL (the
  # serializer ships *_origin fallbacks). Retried by Sidekiq on raise — but we
  # never raise; a permanently missing upload just stays origin-served.
  class DiscourseShortsMirrorMedia < ::Jobs::Base
    sidekiq_options queue: "low"

    def execute(args)
      return unless ::DiscourseShorts::Media.mirror_uploads?

      [args[:upload_id], args[:poster_upload_id]].compact.each do |uid|
        upload = ::Upload.find_by(id: uid.to_i)
        next if upload.nil?
        ::DiscourseShorts::Media.mirror_upload!(upload)
      end
    end
  end
end
