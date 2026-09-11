# Directory Restructure — Design

**Date:** 2026-09-11
**Branch:** `refactor/directory-structure` (from `main`)

## Problem

The repository now hosts both Radarr and Sonarr automation, but the shared
library `scripts_common.sh` lives under the `radarr/` namespace. The Sonarr
script reaches across it with `../../radarr/connect/scripts_common.sh`. The
single `radarr/connect/scripts.conf` is also app-agnostic despite living under
`radarr/connect/`.

## Target layout

```
common/
  scripts_common.sh          # shared library (moved from radarr/connect/)
  tmdb_login.sh              # TMDB cookie export; not radarr-specific (moved from radarr/)
  push_physical_to_tmdb.sh   # pushes dates to TMDB website; no radarr API usage (moved from radarr/)
  scripts.conf.sample        # shared config (new), plus local scripts.conf
radarr/
  connect/
    tag_dvfelmel.sh          # stays
    download_trailer.sh      # stays
  auto_quality_switch.sh
  auto_quality_switch_reverse.sh
  fix_quality_profiles.sh
  fetch_physical_dates.sh    # only radarr script tied to TMDB push flow
  research/
    release_date_stats.sh    # stays nested
  scripts.conf.sample        # radarr config (moved from connect/), plus local scripts.conf
sonarr/
  connect/
    download_recap.sh        # added by the recap feature branch, flattened after rebase
  scripts.conf.sample        # sonarr config
```

- `connect/` directories stay where they are: they hold the Connect-hook
  scripts, config does not.
- Config files move from `radarr/connect/` to the app roots — one config per
  app plus one shared config for common credentials.
- `.gitignore` already matches `scripts.conf` at any depth (global pattern),
  so new locations stay ignored automatically.

## Config model (cascading)

Two-level cascade in `load_config()`:

1. Shared: `"${config_dir}/../common/scripts.conf"`
2. App: `"${config_dir}/scripts.conf"` — sourced last, wins on collision.

Contents split:

- `common/scripts.conf*`: `TMDB_API_KEY`, `TMDB_USERNAME`, `TMDB_PASSWORD`,
  `TMDB_COOKIE_FILE`, `YT_DLP_COOKIE_FILE`, `YT_DLP_FORMAT`, `YT_DLP_RECODE`,
  `AUTOPULSE_URL`, `AUTOPULSE_TRIGGER`, `AUTOPULSE_AUTH_USER`,
  `AUTOPULSE_AUTH_PASS`.
- `radarr/scripts.conf*`: `RADARR_API_URL`, `RADARR_API_KEY`, and Radarr
  script-specific variables (`RADARR_TAG_*` used by tag script, etc.).
- `sonarr/scripts.conf*`: `SONARR_API_URL`, `SONARR_API_KEY`, and recap
  variables (`RECAP_LANGUAGES`, `RECAP_SUBTITLE_LANGS`, `FAN_MADE`,
  `STORAGE_MODE`).

`load_config($1)` accepts the app config dir; the shared config is derived as
`../common` from it. For `common/` scripts (`tmdb_login.sh`,
`push_physical_to_tmdb.sh`, config dir defaults to `common/`), both paths
resolve to the same `common/scripts.conf` — sourced twice, harmless.

Note: some scripts currently pass `"$(dirname "$0")/connect"` as the config
dir; after the restructure every script passes its app root (or relies on the
default which already is the app root for top-level scripts).

## Script path updates

| Script | Common source | `load_config` arg |
|---|---|---|
| `radarr/connect/*` (`tag_dvfelmel`, `download_trailer`) | `. "$(dirname "$0")/../../common/scripts_common.sh"` | `"$(dirname "$0")/.."` |
| `radarr/*` top level (auto quality, profiles, fetch dates) | `. "$(dirname "$0")/../common/scripts_common.sh"` | default |
| `radarr/research/release_date_stats.sh` | `. "$(dirname "$0")/../../common/scripts_common.sh"` | `"$(dirname "$0")/.."` |
| `common/tmdb_login.sh`, `common/push_physical_to_tmdb.sh` | `. "$(dirname "$0")/scripts_common.sh"` | default |
| `sonarr/connect/*` (post-rebase) | `. "$(dirname "$0")/../../common/scripts_common.sh"` | `"$(dirname "$0")/.."` |

The `scripts.conf.sample` headers ("Move this file to 'scripts.conf' in the
same directory as the connect/custom/trigger scripts") are rewritten for the
new layout, referencing the common config explicitly.

## Docs updates

Every path/example reference in docs and in-file text must match the new
layout. Audit is exhaustive — no stale references may remain.

- `README.md`:
  - Config setup commands: `cp radarr/connect/scripts.conf.sample
    radarr/connect/scripts.conf` → `cp common/scripts.conf.sample
    common/scripts.conf` plus `cp radarr/scripts.conf.sample
    radarr/scripts.conf`.
  - "`scripts.conf`" prose references (config description, trailer/tag/recap
    sections) → name the correct file: `common/scripts.conf` for shared vars
    (TMDB, yt-dlp, autopulse), `radarr/scripts.conf` or `sonarr/scripts.conf`
    for app vars.
  - `tmdb_login.sh` and `push_physical_to_tmdb.sh` invocations →
    `./common/...`, including the pipe example
    (`fetch_physical_dates.sh ... | common/push_physical_to_tmdb.sh`) and the
    cron example.
  - Sonarr/recap section: `sonarr/connect/scripts.conf` → `sonarr/scripts.conf`
    (updated during the recap branch rebase).
  - Top-level radarr script paths (`./radarr/auto_quality_switch.sh`, cron
    `/path/to/radarr/...`) are unchanged and stay.
- `docs/cookie-extraction.md`: point the `YT_DLP_COOKIE_FILE` setup at
  `common/scripts.conf`.
- `AGENTS.md`: script list refs (`radarr/connect/…` → `common/…` where moved),
  shellcheck commands, run commands, File Organization tree, dependency list
  (add `common/`), config-setup text.
- `scripts.conf.sample` header comments ("same directory as the
  connect/custom/trigger scripts") → rewritten for the new layout. `common/`
  sample gains an explicit "sourced by every app config; app configs override"
  note.
- Error/help text in scripts: `tmdb_login.sh` "must be set in scripts.conf" →
  "must be set in common/scripts.conf". Other error texts referencing
  `scripts.conf` generically are fine.

## Manual user step (not in this branch)

Local gitignored config files are not tracked, so this branch cannot move
them. After merge the operator must:

- Split existing `radarr/connect/scripts.conf` into `common/scripts.conf`
  (shared creds) and `radarr/scripts.conf` (radarr vars).
- Create `sonarr/scripts.conf` from the new sample when deploying the recap
  script.

## Script namespace audit

Audited every script in `radarr/` for radarr API/host usage. Non-radarr
scripts move to `common/`:

- `tmdb_login.sh` — no radarr references.
- `push_physical_to_tmdb.sh` — no radarr references; pure TMDB website Kendo
  grid API, fed by CLI args or JSON from `fetch_physical_dates.sh`.

All other radarr scripts use `radarr_api_get`, `RADARR_API_URL/KEY` and stay.

## Branch sequencing

1. This branch merges to `main`.
2. `feat/sonarr-recap-downloader` is rebased onto the new `main`: its scripts
   adopt the new `../../common/` source path, `load_config` arg, and
   `sonarr/scripts.conf` error text; the sonarr config sample moves to
   `sonarr/`; shared defaults + helpers it added to `scripts_common.sh` land in
   `common/scripts_common.sh`.

## Verification

- `git grep -E "connect/(scripts_common|scripts\.conf)"` → no stale hits.
- `git grep -n "radarr/(tmdb_login|push_physical_to_tmdb)"` → no stale hits in
  README/AGENTS/cron examples.
- `git grep -n "radarr/connect/"` → only the connect-scripts' own relative
  source references remain.
- `sh -n` + `shellcheck -e SC1091,SC3043` on every touched script.
- Test-event run: `TMDB_API_KEY=x ./radarr/connect/download_trailer.sh Test`
  exits 0.