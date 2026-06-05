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
