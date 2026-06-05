# frozen_string_literal: true
module DiscourseShorts
  # Inserts LF Builders' own (uploaded) videos into the library once. These are
  # provider="upload", source="owned", credited to the brand account, and carry a
  # gentle ranking priority so they stay in rotation without dominating the feed.
  # Idempotent + flag-guarded (a PluginStore flag) so admin deletes stick.
  module OwnedSeeder
    SEED_FLAG = "owned_seeded_v1"
    OWNER_USERNAME = "BuildersLTD"

    # video_id, title, tags, video_url (https), upload_ref (upload://), poster_url (https)
    MANIFEST = [
      ["lfv-josh-deck", "Josh builds a deck", "deck,carpentry,build,learn",
       "https://renovation-reviews.storage.googleapis.com/original/3X/4/d/4d66e223aa3edc626ec534414573a8c77660fd4b.mp4",
       "upload://b2JbThf7Jnwqju8NsADshFxT0fN.mp4",
       "https://renovation-reviews.storage.googleapis.com/original/3X/e/0/e012278c93a92fd42a778234fa9deaf3d83ceda3.jpeg"],
      ["lfv-ryan-foreman", "Ryan the foreman", "jobsite,foreman,construction,behindthescenes",
       "https://renovation-reviews.storage.googleapis.com/original/3X/1/7/1752b349361ac9b204c9c9b78faa6327d5b84118.mp4",
       "upload://3kkajV7mMBHCVSbUddUCVq2iwBi.mp4",
       "https://renovation-reviews.storage.googleapis.com/original/3X/4/2/42ab17d9482a8ed606539ac39213d810b2a598df.jpeg"],
      ["lfv-samm-bigreno", "Samm at a big reno", "reno,samm,renovation,jobsite",
       "https://renovation-reviews.storage.googleapis.com/original/3X/0/f/0ffaf40454710a74b4a390438c6f8b5e8ebee800.mp4",
       "upload://2hmPgaWPsPM3jnGfIBoKabHEOM8.mp4",
       "https://renovation-reviews.storage.googleapis.com/original/3X/3/0/30835b061badb02b94c0d7aa17db4d98f07ec381.jpeg"],
      ["lfv-samm-greenhouse", "Samm builds a greenhouse", "greenhouse,build,samm,sustainable,learn",
       "https://renovation-reviews.storage.googleapis.com/original/3X/a/e/ae32f19d648b4e7c4528a5a522877cf68aea75df.mp4",
       "upload://oR2e2wvd2eapp6cjGSzSUW1x6sT.mp4",
       "https://renovation-reviews.storage.googleapis.com/original/3X/9/2/927e621cdc8e8d8bf2a7ae5f1ef1e94fa583a02a.jpeg"],
      ["lfv-kungfu", "Kung fu on the jobsite", "fun,personality,behindthescenes",
       "https://renovation-reviews.storage.googleapis.com/original/3X/0/3/0310651c632091ef603789b0608e625a616a95f1.mp4",
       "upload://r6yCINeDo1eQZwfpfxKtr4GkjT.mp4",
       "https://renovation-reviews.storage.googleapis.com/original/3X/1/2/12ffe82328e41f904dbb82caba1cc1f89205d6ec.jpeg"],
      ["lfv-oldschool-frank", "Old school Frank", "fun,oldschool,personality",
       "https://renovation-reviews.storage.googleapis.com/original/3X/3/f/3fe991f6ce68082712e63669c59cfa5caaaf6a64.mp4",
       "upload://97ov9jMRFy39xXVWw7MOaicrLqQ.mp4",
       "https://renovation-reviews.storage.googleapis.com/original/3X/d/e/de8d48b9f3d4bd35962412f1338f5fddbb2bf6f9.jpeg"],
    ].freeze

    def self.run!
      return if PluginStore.get(::DiscourseShorts::PLUGIN_NAME, SEED_FLAG)
      owner = ::User.find_by(username_lower: OWNER_USERNAME.downcase) || ::Discourse.system_user
      prio = (SiteSetting.shorts_owned_priority.to_i rescue 10)
      MANIFEST.each do |vid, title, tags, url, ref, poster|
        next if Short.exists?(video_id: vid)
        begin
          Short.create!(
            video_id: vid, provider: "upload", title: title, tags: tags,
            video_url: url, upload_ref: ref, poster_url: poster,
            submitted_by_id: owner&.id, status: "approved", source: "owned",
            priority: prio
          )
        rescue ActiveRecord::RecordNotUnique
          # already present from a race; fine
        rescue => e
          Rails.logger.warn("[discourse-shorts] owned seed #{vid} failed: #{e.class} #{e.message}")
        end
      end
      PluginStore.set(::DiscourseShorts::PLUGIN_NAME, SEED_FLAG, true)
    end
  end
end
