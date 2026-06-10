# frozen_string_literal: true
module DiscourseShorts
  # CLOUDFLARED MODE (v0.5.0): serve shorts media (mp4/vp9/posters) from a
  # Cloudflare R2 bucket behind a custom domain (free egress + edge cache +
  # HTTP/2 range requests) instead of the Discourse upload store (GCS).
  #
  # Design: READ-TIME remap, not a data migration. The DB keeps the original
  # store URLs (origin of truth); when shorts_cloudflare_enabled is on and the
  # URL's host is in shorts_cloudflare_rewrite_hosts, the serializer swaps
  # scheme+host for shorts_cloudflare_base_url and keeps the path verbatim.
  # This works because the R2 bucket mirrors the store's object layout
  # (original/3X/<sha1-prefixed path>). Flip the setting off and every URL
  # instantly reverts to the store — zero-risk rollback, no rebuild needed.
  #
  # New creator uploads are mirrored into R2 asynchronously (Jobs enqueue from
  # CreatorController) under the same store-derived key, so the read-time remap
  # covers them too. Mirror failure degrades gracefully: the serializer only
  # remaps, the origin URL still ships as *_origin for client-side fallback.
  module Media
    module_function

    MIME = {
      "mp4" => "video/mp4", "m4v" => "video/mp4", "webm" => "video/webm",
      "mov" => "video/quicktime", "jpg" => "image/jpeg", "jpeg" => "image/jpeg",
      "png" => "image/png", "webp" => "image/webp", "gif" => "image/gif",
    }.freeze

    def enabled?
      SiteSetting.shorts_cloudflare_enabled &&
        SiteSetting.shorts_cloudflare_base_url.to_s.start_with?("https://")
    rescue StandardError
      false
    end

    def base_url
      SiteSetting.shorts_cloudflare_base_url.to_s.chomp("/")
    end

    def rewrite_hosts
      SiteSetting.shorts_cloudflare_rewrite_hosts.to_s
        .split("|").map { |h| h.strip.downcase }.reject(&:empty?)
    end

    # A token mixed into shared cache keys so flipping cloudflared mode (or the
    # base URL) invalidates cached serialized payloads instead of serving the
    # other mode's URLs for up to the cache TTL.
    def cache_token
      enabled? ? "cf#{base_url.hash.abs % 100_000}" : "cf0"
    end

    # Remap a single absolute (or protocol-relative) store URL to the CDN.
    # Anything that isn't enabled / parseable / on a rewrite host passes
    # through untouched. NEVER raises.
    def cdn(url)
      return url if url.blank?
      return url unless enabled?
      s = url.to_s
      s = "https:#{s}" if s.start_with?("//")
      u = begin
        URI.parse(s)
      rescue StandardError
        nil
      end
      return url unless u&.host && rewrite_hosts.include?(u.host.downcase)
      "#{base_url}#{u.path}"
    end

    # Returns [cdn_url, origin_url_or_nil]. origin is non-nil only when a
    # remap actually happened — serializers ship it as *_origin so the player
    # can fall back if the edge object is missing (e.g. mirror still running).
    def cdn_pair(url)
      mapped = cdn(url)
      mapped == url ? [url, nil] : [mapped, url.to_s]
    end

    # ---- R2 write path (S3-compatible) --------------------------------------

    def uploads_configured?
      SiteSetting.shorts_cloudflare_s3_endpoint.to_s.start_with?("https://") &&
        SiteSetting.shorts_cloudflare_s3_bucket.present? &&
        SiteSetting.shorts_cloudflare_s3_access_key_id.present? &&
        SiteSetting.shorts_cloudflare_s3_secret_access_key.present?
    rescue StandardError
      false
    end

    def mirror_uploads?
      enabled? && SiteSetting.shorts_cloudflare_mirror_uploads && uploads_configured?
    end

    def s3_client
      # aws-sdk-s3 ships with Discourse core (powers enable_s3_uploads).
      require "aws-sdk-s3" unless defined?(::Aws::S3::Client)
      ::Aws::S3::Client.new(
        endpoint: SiteSetting.shorts_cloudflare_s3_endpoint,
        access_key_id: SiteSetting.shorts_cloudflare_s3_access_key_id,
        secret_access_key: SiteSetting.shorts_cloudflare_s3_secret_access_key,
        region: "auto",
        force_path_style: true,
      )
    end

    # Mirror one Discourse Upload into R2 under its store-derived key
    # ("original/3X/a/b/<sha1>.<ext>"), preserving the layout the read-time
    # remap depends on. Idempotent (PUT overwrite = same bytes, sha1-keyed).
    # Returns the object key on success, nil on failure (logged, never raises).
    def mirror_upload!(upload)
      return nil unless mirror_uploads?
      return nil if upload.nil?

      key = Discourse.store.get_path_for_upload(upload).to_s.sub(%r{\A/+}, "")
      return nil if key.empty?

      tmp = nil
      path =
        if Discourse.store.external?
          tmp = Discourse.store.download!(upload)
          tmp.path
        else
          Discourse.store.path_for(upload)
        end
      return nil if path.blank? || !File.exist?(path)

      ext = upload.extension.to_s.downcase
      File.open(path, "rb") do |body|
        s3_client.put_object(
          bucket: SiteSetting.shorts_cloudflare_s3_bucket,
          key: key,
          body: body,
          content_type: MIME[ext] || "application/octet-stream",
          cache_control: "public, max-age=31536000, immutable",
        )
      end
      Rails.logger.info("[discourse-shorts] mirrored upload #{upload.id} -> r2:#{key}")
      key
    rescue StandardError => e
      Rails.logger.warn("[discourse-shorts] r2 mirror failed for upload #{upload&.id}: #{e.class} #{e.message}")
      nil
    ensure
      begin
        tmp.close! if tmp.respond_to?(:close!)
      rescue StandardError
        nil
      end
    end
  end
end
