# Design: download_recap.sh v0.2.0 — recap quality and storage fixes

Date: 2026-09-11
Status: Approved (design), pending spec review

## Problem

`download_recap.sh` v0.1.0 bulk run produced unusable output:

1. **Filename collision / overwrite.** Every candidate for a season+lang is
   downloaded to the same `-o` target (e.g. `Recap-S04-official-en.mp4`). On a
   real run each yt-dlp invocation overwrites the previous file — the judged
   "best" result is whatever YouTube returned last, and 6+ downloads were
   queued for one logical file.
2. **Wrong season folder.** A recap of season N was stored in `Season N`. The
   recap is watched *before* season N+1, so it belongs in the `Season N+1`
   folder. Filename must still name the recapped season.
3. **Duplicate videos across languages.** YouTube ignores the `pt-BR` token in
   the search query and returns the same English videos for every configured
   language. Identical video ids were queued as `official/en` and as
   `official/pt-BR`, and English recaps got mislabeled pt-BR.
4. **Junk results.** YouTube "official" search returned trailers, soundtracks,
   reaction videos, single-episode recaps, and Crash Course analysis videos.
   No title validation, no ranking. YouTube search cannot distinguish official
   content reliably and cannot filter by language.
5. **Debug output misses the decision trail.** Bulk mode logged only
   "Processing series", not the Sonarr response, the recap seasons chosen, the
   search queries run, candidate counts, or selection rationale.

## Decisions

- **One download per (recap_season, language).** Pick the single best candidate.
- **Storage under the watched season.** Recap of season N → `Season N+1` folder
  (or `Series/Other` in show mode). Filename keeps the recapped season number.
- **YouTube search for original language only.** Other languages come from TMDB
  where real language tags exist. This eliminates the pt-BR dup/mislabel bug.
- **Title heuristics** for junk filtering and ranking within a source tier.
- **Debug transparency**: log Sonarr response, search queries, candidate counts,
  and selection rationale.
- **Cleanup of pre-existing junk** is a README one-liner, not a script feature.

## Design

### 1. Candidate selection — one per (season, lang)

Discovery stays as-is (TMDB season videos + YouTube search), but instead of
downloading every line of the candidate file, rank candidates and download
only the winner per (recap_season, lang).

Selection order (highest priority first):

1. TMDB official recap (`type == "Recap" && official == true && site == "YouTube"`)
2. YouTube "official" search hit
3. Fan-made search hit

`FAN_MADE` controls whether fan-made candidates enter the pool at all:

- `never` — fan-made search skipped; winners come from tiers 1-2.
- `fallback` (default) — fan-made searched only when tier 1-2 produced no
  qualifying candidate for that (season, lang).
- `always` — fan-made searched unconditionally and enters the pool, but still
  ranks *below* any qualifying official candidate.

Within the highest tier that produced ≥1 qualifying candidate, pick the title
whose heuristic score is highest. Ties break to the first candidate read.

Consequence: at most one file per (recap_season, lang). Fixes overwrite,
dup-across-language, and junk-in-filename problems.

### 2. Storage semantics

- Recap of season N is stored in the folder of season N+1 (the season the
  viewer will watch next).
- Filename format unchanged apart from placement: `Recap-S0{N}-${source}-${lang}.mp4`
  where N is the *recapped* season.
- Event mode (`SEASON_NUMBER` set): recap season = `SEASON_NUMBER - 1`, stored
  in `Season ${SEASON_NUMBER}/Other/`.
- Backfill mode: for each downloaded season N ≥ 2, recap season = N - 1, stored
  in `Season N/Other/`.
- `STORAGE_MODE=show`: all recaps → `Series/Other/`.
- `STORAGE_MODE=both`: download lands in `Series/Other/`, hardlink (fallback
  copy) into `Season N+1/Other/`.
- `recap_exists` checks show-level `Other/Recap-S0N-*` and
  `Season N+1/Other/Recap-S0N-*`.

### 3. YouTube search — original language only

- YouTube recap search (official and fan-made) runs only for the series
  original language (`_series_lang`).
- Other configured languages (e.g. `pt-BR`) are sourced from TMDB only.
- Dedupe results by video id within a search, and across tiers where the same
  id appears more than once (highest tier wins).
- Search result count configurable: `RECAP_SEARCH_COUNT` (default 10), so
  heuristics have more candidates to rank without exploding traffic.
  Applied to the `ytsearchN` width.

### 4. Title heuristics

Applied to every candidate before ranking.

**Junk blocklist** — drop if title contains any token (case-insensitive):
`trailer`, `teaser`, `soundtrack`, `reaction`, `review`, `interview`,
`episode`, `crash course`, `live`, `official music`.

- `crash course` also catches "Crash Course Literature" analyses.

Plus: YouTube-sourced candidates must contain the word `recap` in the title.
TMDB-sourced candidates skip this because the `type` field already qualifies
them.

**Ranking score** (higher better) within a tier:
- +2 if title contains the season token (e.g. `season 5`, `s05`, `season 5
  recap`, `1-5 recap`, "before season 6")
- +1 if title contains `recap`
- +1 if title contains `before season` (recaps aimed at the upcoming season)
- 0 otherwise

### 5. Debug transparency

Add `debug_log` lines:
- Per series in backfill: seasons-with-files list and chosen recap seasons
  (e.g. `DEBUG: Series 'X': downloaded seasons >= 2: 4 5 6`, then per season
  `DEBUG: S06 started, seeking recap of S05`).
- Per search: query + result count + kept-after-filter count
  (e.g. `DEBUG: ytsearch10 'Handmaid's Tale season 5 recap en': 10 results, 3 qualify`).
- Selection: `DEBUG: Selected 'title' (official/en) for recap S05`.
- Keep existing `DEBUG`/`DRY_RUN` flag handling (already decoupled).

### 6. Junk cleanup one-liner (README, not script)

```sh
find /path/to/Series -path "*/Other/Recap-*" -type f -delete
```

## Config changes

New: `RECAP_SEARCH_COUNT` (default 10). Documented in `sonarr/scripts.conf.sample`.
No other config changes.

## Edge cases

- **Season 1**: no previous season, recap skipped (existing behavior).
- **Season 0 / specials**: skipped (existing behavior).
- **Series with years in title / braces paths**: searches use the Sonarr title
  as today; only storage path and selection change.
- **Multiple recap seasons in one backfill run**: recursion is per season;
  each season is independent, one winner per (season, lang).
- **Same video id returned for original lang official + fanmade tiers**: dedupe,
  higher tier wins.
- **TMDB returns no recap for a language**: no download for that lang; YT is
  original-lang only, so the lang simply produces nothing instead of a
  mislabeled English video.

## Open questions resolved

- ~~Should fan-made search also be original-lang only?~~ Yes, consistent with
  language-fidelity decision.
- ~~Script flag for junk cleanup?~~ No — README one-liner. YAGNI.