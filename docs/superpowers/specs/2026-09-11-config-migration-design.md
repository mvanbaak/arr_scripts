# Config Migration Design

## Problem

The directory restructure (PR #8) moves config from `radarr/connect/scripts.conf` to `radarr/scripts.conf` + `common/scripts.conf`. Existing users with config at the old path will silently lose all settings — scripts fall back to garbage defaults (`ip:7878`). No error, just broken behavior.

## Design

### 1. Migration fallback in `load_config()`

After the normal cascade (common → app config), if neither new config file exists, check for `${_app_dir}/connect/scripts.conf` (the old path). If found:

- Print warning to stderr with exact `cp` command
- Source the old config as fallback
- Include deprecation notice ("will be removed in a future update")

This keeps scripts working while nudging users to migrate. The fallback check uses `_app_dir` (resolved absolute path) so it works from any calling depth.

### 2. Migration script (`radarr/migrate_config.sh`)

One-shot script:
1. Check if `radarr/connect/scripts.conf` exists
2. Check if `radarr/scripts.conf` already exists
3. If old exists and new doesn't: `cp` old → new
4. Print what was done + instructions to optionally split shared vars (TMDB_API_KEY, YT_DLP_*) to `common/scripts.conf`
5. Old file left in place as backup

No flags, no interactivity. Just run it.

### 3. Docs

**README.md:** "Migration from old layout" section near the top, before Quick start. Covers:
- What changed (config path)
- How to migrate (run script or manual cp)
- What the fallback does and that it will be removed

**PR #8 body:** Breaking changes callout with migration instructions.

## Scope

- `common/scripts_common.sh`: add migration fallback check
- `radarr/migrate_config.sh`: new file
- `README.md`: migration section
- PR #8 body: update
