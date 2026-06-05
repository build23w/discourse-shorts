# discourse-shorts

A short-form video library for the Home Renovation Reviews feed. Stores YouTube
short **IDs only** (no video hosting — playback streams from YouTube), with
moderation, member submissions, persisted engagement metrics, and scheduled
auto-ingest. Pairs with the **LF Feed Images** theme (id 33), which renders the
rail, the in-feed shorts, and the full-screen vertical player.

## Install
1. Add to `containers/app.yml` under hooks (or clone into `plugins/`):
   `git clone <your-repo>/discourse-shorts`
2. `cd /var/discourse && ./launcher rebuild app`
3. Admin → Settings → search "shorts" to configure.

## What it does
- **Library**: `discourse_shorts` table (video_id, title, tags, status, source,
  likes, dislikes, views, watch_seconds). `GET /shorts.json?limit=N` returns the
  approved list ordered by net likes; the theme consumes this automatically and
  falls back to its built-in list if the plugin isn't installed.
- **Member submissions**: `POST /shorts` `{url|video_id, title, tags}`. Allowed for **staff always**, plus members at/above `shorts_min_submit_trust_level` when `shorts_allow_member_submissions` is on. The URL/ID is validated via
  YouTube oEmbed (must exist AND be embeddable) and de-duped. Auto-approved for
  users at/above `shorts_auto_approve_trust_level`, else queued `pending`.
- **Moderation**: `GET /shorts/admin/list`, `PUT|DELETE /shorts/admin/:id` — list pending,
  approve / reject / delete.
- **Engagement persistence**: `POST /shorts/:id/react {dir: up|down|clear}` (one
  per user, toggle) and `POST /shorts/:id/watch {seconds}` (views + watch-time).
- **Auto-ingest**: `Jobs::DiscourseShortsIngest` runs every 6h when
  `shorts_ingest_enabled` + `shorts_youtube_api_key` are set. Searches the
  YouTube Data API for each term in `shorts_ingest_terms` (short, embeddable),
  validates via oEmbed, inserts new approved shorts up to `shorts_max_library`.

## Settings
| setting | default | purpose |
|---|---|---|
| `shorts_enabled` | true | master switch (client-visible) |
| `shorts_allow_member_submissions` | true | let non-staff submit (staff can always) |
| `shorts_min_submit_trust_level` | 3 | min trust level to submit (when members allowed) |
| `shorts_auto_approve_trust_level` | 3 | TL ≥ this auto-approves submissions |
| `shorts_max_library` | 2000 | ingest stops at this many approved (0 = ∞) |
| `shorts_ingest_enabled` | false | enable the scheduled ingest job |
| `shorts_youtube_api_key` | "" (secret) | YouTube Data API v3 key (server-side) |
| `shorts_ingest_terms` | renovation terms | list, `|`-separated, ingest queries |

## Notes
- The API key stays server-side (only the ingest job uses it) — never exposed to
  the browser.
- To seed the library from the theme's current 121 hardcoded IDs, submit them
  (staff) or insert directly; after that the theme auto-switches to the DB list.

## v0.2.0 — LF-produced uploads, owner attribution, $RENO payouts, comments

- **provider="upload"**: shorts can now be LF-hosted mp4s (Discourse uploads) in addition to YouTube. New columns: `video_url`, `upload_ref` (upload://), `poster_url`, `topic_id`, `comment_count`, `priority`.
- **Owner attribution**: each short serializes an `owner` block (`username`, `avatar_template`, `path` → `/u/<username>`). The theme renders the avatar; clicking it opens the profile.
- **Algorithmic precedence (gentle)**: `priority` adds a small head-start in the index ordering `(likes - dislikes + priority)`; owned LF videos seed at `shorts_owned_priority` (default 10). Not a top-lock — real engagement overtakes it.
- **$RENO payouts**: a NEW like pays the short's author (mirrors post-upvote rewards) via `DiscourseCoinEngine.credit_score` + MessageBus toast. Settings: `shorts_reward_enabled`, `shorts_like_reward_amount` (2), `shorts_reward_min_trust_level` (1), daily caps per-short (50) / per-author (200). Self-likes, owned videos, and staff authors never pay; `rewarded` flag prevents double-pay.
- **Comment → topic system**: `GET/POST /shorts/:id/comments.json`. The first comment auto-creates a real Discourse topic (video embedded in the OP) in the Shorts category (`shorts_comment_category_id`, falls back to the `shorts` category slug); every comment is a normal reply living in that topic and is pulled back into the short's comment list. Login required; rate-limited 12/hr.
- **Sign-in gating**: react/watch/comment endpoints require login server-side; the theme redirects anon users to `/login` on any short interaction.
- **Owned seeder**: `lib/discourse_shorts/owned_seeder.rb` inserts LF's 6 uploaded videos once (flag-guarded), credited to `BuildersLTD`.
