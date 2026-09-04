# frozen_string_literal: true
module DiscourseShorts
  # Server-side comment system: the first comment on a short auto-creates a real
  # Discourse topic (video embedded in the OP) in the Shorts category; every
  # comment is a normal reply that lives in that topic, and the short's comment
  # list is pulled straight back out of it. So comments are first-class Discourse
  # posts — searchable, moderatable, notifiable — not a side table.
  module Discussions
    module_function

    def category_id
      cid = SiteSetting.shorts_comment_category_id.to_i
      return cid if cid.positive?
      ::Category.find_by(slug: "shorts")&.id
    end

    def embed_raw(short)
      if short.provider == "upload" && short.upload_ref.present?
        "![#{short.title}|video](#{short.upload_ref})\n\n"
      elsif short.provider == "upload" && short.video_url.present?
        "#{Media.cdn(short.video_url)}\n\n"
      else
        # YouTube → onebox player
        "https://www.youtube.com/watch?v=#{short.video_id}\n\n"
      end
    end

    # Credit the ORIGINAL creator so our authors benefit the most: for YouTube,
    # name + a subscribe link to their channel; for LF uploads, brand credit.
    def credit_raw(short)
      if short.provider == "upload"
        owner = short.submitted_by_id && ::User.find_by(id: short.submitted_by_id)
        name = (owner&.name.presence || owner&.username.presence || "LF Builders")
        return "🎬 An **LF Builders** original by **#{name}**.\n\n"
      end
      meta = (DiscourseShorts::Youtube.oembed(short.video_id) rescue nil)
      return "" unless meta && meta["author_name"].to_s.strip.present?
      an = meta["author_name"].to_s.strip
      au = meta["author_url"].to_s.strip
      if au.present?
        sub = au + (au.include?("?") ? "&" : "?") + "sub_confirmation=1"
        "🎬 Original video by **[#{an}](#{au})** — [**Subscribe on YouTube** ▶](#{sub}) to support the creator.\n\n"
      else
        "🎬 Original video by **#{an}** on YouTube.\n\n"
      end
    end

    def build_title(short)
      base = short.title.to_s.strip
      base = "LF Builders short" if base.blank?
      min = (SiteSetting.min_topic_title_length.to_i rescue 15)
      base = "#{base} — community short" if base.length < min
      base[0, 240]
    end

    # Returns the topic_id (creating the topic if needed). nil on failure.
    def ensure_topic!(short)
      if short.topic_id.present?
        return short.topic_id if ::Topic.exists?(id: short.topic_id, deleted_at: nil)
      end
      cid = category_id
      owner = (short.submitted_by_id && ::User.find_by(id: short.submitted_by_id)) || ::Discourse.system_user
      # v0.8.1: the creator's description (when there is one) and a link to the
      # short's own page make this a real topic instead of a boilerplate stub —
      # it is what crawlers and the topic-list excerpt see.
      desc = short.try(:description).to_s.strip
      cat_key = short.try(:category).presence || "general"
      cat_label = Journey::AREA_LABELS[cat_key] || cat_key.to_s.tr("-", " ").capitalize
      raw = embed_raw(short) +
            credit_raw(short) +
            (desc.present? ? "#{desc}\n\n" : "") +
            "Watch the short and join the conversation 👇 " \
            "More #{cat_label.downcase} shorts: #{Discourse.base_url}/shorts/v/#{ERB::Util.url_encode(short.video_id)}\n\n" \
            "*(This topic was created automatically from a community short.)*"
      pc = ::PostCreator.new(
        owner,
        title: build_title(short),
        raw: raw,
        category: cid,
        skip_validations: true,
        skip_jobs: false,
        custom_fields: { discourse_short_id: short.id }
      )
      post = pc.create
      if pc.errors.any?
        Rails.logger.warn("[discourse-shorts] topic create failed for short #{short.id}: #{pc.errors.full_messages.join(', ')}")
        return nil
      end
      short.update_columns(topic_id: post.topic_id)
      post.topic_id
    end

    def add_comment(short, user, guardian, raw)
      topic = short.topic_id.present? ? ::Topic.find_by(id: short.topic_id, deleted_at: nil) : nil
      unless topic
        category = ::Category.find_by(id: category_id)
        raise Discourse::NotFound unless category && guardian.can_see_category?(category)

        tid = ensure_topic!(short)
        return nil unless tid
        topic = ::Topic.find_by(id: tid, deleted_at: nil)
        return nil unless topic
      end
      guardian.ensure_can_see!(topic)
      pc = ::PostCreator.new(user, topic_id: topic.id, raw: raw.to_s.strip)
      post = pc.create
      return { error: pc.errors.full_messages.join(", ") } if pc.errors.any?
      DiscourseShorts::Short.where(id: short.id).update_all("comment_count = comment_count + 1")
      serialize_post(post, topic)
    end

    def list(short, guardian, limit = 20)
      return { comments: [], topic_id: nil, topic_url: nil, count: 0 } if short.topic_id.blank?
      topic = ::Topic.find_by(id: short.topic_id, deleted_at: nil)
      return { comments: [], topic_id: nil, topic_url: nil, count: 0 } unless topic
      guardian.ensure_can_see!(topic)
      posts = ::Post.secured(guardian).where(topic_id: topic.id, deleted_at: nil)
                    .where("post_number > 1")
                    .where("COALESCE(hidden,false) = false")
                    .order(post_number: :desc).limit(limit).to_a.reverse
      {
        comments: posts.map { |p| serialize_post(p, topic) },
        topic_id: topic.id,
        topic_url: "/t/#{topic.slug}/#{topic.id}",
        count: [topic.posts_count - 1, 0].max
      }
    end

    def serialize_post(post, topic)
      u = post.user
      excerpt = begin
        ::PrettyText.excerpt(post.cooked.to_s, 300, keep_emoji_images: true)
      rescue StandardError
        post.raw.to_s[0, 300]
      end
      {
        post_id: post.id,
        post_number: post.post_number,
        username: u&.username,
        name: u&.name,
        avatar_template: u&.avatar_template,
        excerpt: excerpt,
        created_at: post.created_at,
        url: topic ? "/t/#{topic.slug}/#{topic.id}/#{post.post_number}" : nil
      }
    end
  end
end
