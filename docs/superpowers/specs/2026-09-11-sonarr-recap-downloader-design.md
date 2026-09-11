# Sonarr Season Recap Downloader — Design

Date: 2026-09-11
Status: Approved for implementation

## Problem

TV show seasons are often released years apart. When a new season starts, getting
back into the story is hard without a recap of the previous season. Recaps are
currently found manually on YouTube.

Goal: automatically download the previous season's recap when a new season
starts, stored following the Plex naming scheme for TV show extras.

## Design Decisions

### Video sources

Three candidate providers were validated:

- **TMDB** — has a season videos endpoint
  (`/3/tv/{series_id}/season/{season_number}/videos`) that returns videos with a
  `type` field including `"Recap"` and an `official` boolean. Primary source. No
  API cost if a free API key is used.
- **TVDB** — no video content in the API (artwork/trailers system only). Not usable.
- **OMDb** — metadata only, no video content. Not usable.

### Discovery chain

For the previous season of a newly-started season:

1. **TMDB** — season videos endpoint, filter `type == "Recap"` and
   `official == true`, per language in `RECAP_LANGUAGES`.
2. **YouTube official search** — only if TMDB returned nothing. Query:
   `"series_name" "season X" recap official`.
3. **YouTube fan-made search** — controlled by `FAN_MADE` config:
   - `never` — skip entirely
   - `fallback` (default) — only if steps 1+2 found nothing
   - `always` — always search, download in addition to any official recap

### Filenames

`Recap-S{season:02d}-{source}-{lang}.mp4` where source is `official` or
`fanmade`. Example: `Recap-S01-official-en.mp4`.

The source suffix is always present, so official and fan-made recaps never
overwrite each other.

### Storage (Plex extras naming)

Plex recognizes show-level and season-level extras inside directory type
directories. Valid types:`Behind The Scenes`, `Deleted Scenes`, `Featurettes`,
`Interviews`, `Scenes`, `Shorts`, `Trailers`, `Other`. There is no "Recaps"
type, so recaps go under `Other`.

Config `STORAGE_MODE`:

- `show` (default) — `ShowName (Year)/Other/Recap-S01-official-en.mp4`
- `season` — `ShowName (Year)/Season 01/Other/Recap-S01-official-en.mp4`
- `both` — download to show level, hardlink to season level. If `ln` fails
  (different filesystem edge case), fall back to `cp`.

Show-level is the default because only iOS/Android mobile clients fully support
season-level extras; show-level works on all clients.

### Languages

Same model as the trailer script:

- `RECAP_LANGUAGES=original,pt-BR` — comma-separated. `original` resolves the
  series' original language to ISO 639-1 via `lang_to_iso639_1()`.
- `RECAP_SUBTITLE_LANGS=pt-BR` — yt-dlp `--write-subs --sub-langs` flags, applied
  only to original-language recaps.

TMDB queries filter by language param. YouTube search appends language to the
query string. YouTube results are predominantly in the show's original language
(no precise language filtering possible on YouTube search).

### Trigger & invocation

- Sonarr Connect webhook, `EpisodeDownload` event.
- On trigger, if downloaded episode is S01E01 of a season, discover recap for
  the previous season. Skip season 0 (specials) and season 1 (nothing to recap).
- CLI invocation for manual runs and backfill:
  `./download_recap.sh [-n] [-d] [event_type] [series_id] [season_number]`
- `bulk` event type iterates all Sonarr series and downloads missing recaps.

### Shared library additions

`scripts_common.sh` gains Sonarr API helpers alongside the existing Radarr ones:

- `SONARR_API_URL` / `SONARR_API_KEY` config defaults in `load_config()`
- `sonarr_api_get()` — same pattern as `radarr_api_get()`
- `get_series_info()` — fetch series JSON by ID

Config defaults that are identical between the trailer script and this script move
into `scripts_common.sh`:

- `TMDB_API_KEY`, `YT_DLP_COOKIE_FILE`, `YT_DLP_FORMAT`, `YT_DLP_RECODE`,
  `AUTOPULSE_URL`, `AUTOPULSE_TRIGGER`, `AUTOPULSE_AUTH_USER`, `AUTOPULSE_AUTH_PASS`

These stay script-specific: `DRY_RUN`, `DEBUG`, language lists, `FAN_MADE`,
`STORAGE_MODE`.

### Series ID mapping

Sonarr series carry a `tvdbId`. TMDB lookups need a TMDB ID. The TMDB `find`
endpoint (`/3/find/{external_id}?external_source=tvdb_id`) maps TVDB → TMDB.

## Error Handling & Edge Cases

- Series with only one season — nothing to recap, skip silently.
- Season 0 (specials) — skip.
- TVDB ID has no TMDB mapping (obscure/special series) — warn, skip.
- YouTube search returns nothing — log, continue.
- Hardlink fails in `both` mode — `cp` fallback, log warning.
- Already downloaded — archived recap check, skip.
- Dry-run never touches filesystem on the download side.

## Files

- New: `sonarr/connect/download_recap.sh`
- Modified: `radarr/connect/scripts_common.sh` (Sonarr helpers + shared defaults)
- Modified: `radarr/connect/download_trailer.sh` (drop duplicated defaults, version bump)
- Modified: `radarr/connect/scripts.conf.sample` (new shared + recap config)
- New: `sonarr/connect/scripts.conf.sample`
- Modified: `README.md`
- Modified: `AGENTS.md`

## Out of Scope

- Fan-made recap download priority/ranking beyond simple "first result".
- Downloading recaps from streaming platforms (only YouTube via yt-dlp).

## Future Work (V2)

- **Season trailer/preview download.** The current season's own trailer is
  typically released right before its premiere, so it is available at trigger
  time. A `DOWNLOAD_SEASON_TRAILER` config toggle (default off) could fetch it
  from the same TMDB season videos endpoint (type Trailer/Teaser) with a
  distinct filename such as `Season{NN}-Trailer-official-en.mp4`. The *next*
  season's trailer is not available until the current season's finale, so it
  cannot be fetched at trigger time.