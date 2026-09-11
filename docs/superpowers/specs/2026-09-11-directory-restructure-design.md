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
  scripts.conf.sample        # shared config (new), plus local scripts.conf
radarr/
  connect/
    tag_dvfelmel.sh          # stays
    download_trailer.sh      # stays
  auto_quality_switch.sh
  auto_quality_switch_reverse.sh
  fix_quality_profiles.sh
  fetch_physical_dates.sh
  push_physical_to_tmdb.sh
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
`../common` from it. For `common/tmdb_login.sh` (config dir defaults to
`common/`), both paths resolve to the same `common/scripts.conf` — sourced
twice, harmless.

Note: some scripts currently pass `"$(dirname "$0")/connect"` as the config
dir; after the restructure every script passes its app root (or relies on the
default which already is the app root for top-level scripts).

## Script path updates

| Script | Common source | `load_config` arg |
|---|---|---|
| `radarr/connect/*` (`tag_dvfelmel`, `download_trailer`) | `. "$(dirname "$0")/../../common/scripts_common.sh"` | `"$(dirname "$0")/.."` |
| `radarr/*` top level | `. "$(dirname "$0")/../common/scripts_common.sh"` | default |
| `radarr/research/release_date_stats.sh` | `. "$(dirname "$0")/../../common/scripts_common.sh"` | `"$(dirname "$0")/.."` |
| `common/tmdb_login.sh` | `. "$(dirname "$0")/scripts_common.sh"` | default |
| `sonarr/connect/*` (post-rebase) | `. "$(dirname "$0")/../../common/scripts_common.sh"` | `"$(dirname "$0")/.."` |

The `scripts.conf.sample` headers ("Move this file to 'scripts.conf' in the
same directory as the connect/custom/trigger scripts") are rewritten for the
new layout, referencing the common config explicitly.

## Docs updates

- `AGENTS.md`: script list refs, shellcheck commands, run commands, File
  Organization tree, dependencies mention.
- `README.md`: config setup commands (`cp radarr/connect/scripts.conf.sample
  ...` → `cp radarr/scripts.conf.sample radarr/scripts.conf`), plus new common
  config step; any `radarr/connect/` path references in prose.
- `docs/cookie-extraction.md`: no path changes needed (references `scripts.conf`
  generically).

## Manual user step (not in this branch)

Local gitignored config files are not tracked, so this branch cannot move
them. After merge the operator must:

- Split existing `radarr/connect/scripts.conf` into `common/scripts.conf`
  (shared creds) and `radarr/scripts.conf` (radarr vars).
- Create `sonarr/scripts.conf` from the new sample when deploying the recap
  script.

## Branch sequencing

1. This branch merges to `main`.
2. `feat/sonarr-recap-downloader` is rebased onto the new `main`: its scripts
   adopt the new `../../common/` source path, `load_config` arg, and
   `sonarr/scripts.conf` error text; the sonarr config sample moves to
   `sonarr/`; shared defaults + helpers it added to `scripts_common.sh` land in
   `common/scripts_common.sh`.

## Verification

- `git grep -E "connect/(scripts_common|scripts.conf)"` → no stale hits.
- `sh -n` + `shellcheck -e SC1091,SC3043` on every touched script.
- Test-event run: `./radarr/connect/download_trailer.sh Test` after a temporary
  test config exists (or with `TMDB_API_KEY` set) exits 0.