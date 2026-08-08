# Quality Profile Fix — Specification

## 1. Problem Statement

Some movies in Radarr carry the wrong quality profile. A concrete case: movies with a physical release date are attached to `[SQP] SQP-3 (Audio)` instead of the Remux-only profile `SQP-3-RemuxOnly`. These movies miss the Remux upgrade once physical media is available.

The existing reverse switch script (`auto_quality_switch_reverse.sh`) only handles movies tagged `auto-switched` by the forward script; it cannot fix movies whose wrong profile was assigned manually.

**Goal:** Detect movies with a physical release date that are on a "wrong" profile and switch them to the correct "remux-only" profile.

## 2. Design Decisions

### 2.1 Detection: profile name + physical release

**Decision:** A movie is a candidate when `physicalRelease != null` and its `qualityProfileId` matches the configured wrong profile name.

**Rationale:**
- Matches the described problem directly (manually-assigned wrong profiles, no tag involved)
- No dependency on `auto-switched` tag from the forward script
- Same API surface as the switch scripts

**Alternatives considered:**
- Require `auto-switched` tag: Rejected — misses manually-assigned wrong profiles, which is exactly the reported case
- Detect all profiles, not just one wrong/correct pair: Rejected — YAGNI, configurable pair covers other cases

### 2.2 Configurable profile pair

**Decision:** Profile names are config variables with SQP-3 defaults, mirroring how the switch scripts expose `SOURCE_PROFILE_NAME` / `TARGET_PROFILE_NAME`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `WRONG_PROFILE_NAME` | `[SQP] SQP-3 (Audio)` | Profile to detect and fix |
| `CORRECT_PROFILE_NAME` | `SQP-3-RemuxOnly` | Profile to switch to |

**Naming note:** `WRONG`/`CORRECT` instead of `SOURCE`/`TARGET` because the switch scripts' "source" is the profile being left, and here the wrong profile is being left — `SOURCE`/`TARGET` would be ambiguous.

### 2.3 Separate script

**Decision:** New standalone script `radarr/fix_quality_profiles.sh`, sibling to the switch scripts.

**Rationale:**
- Reverse script has a single purpose (tag-based revert); adding a profile-based mode muddies it
- Independent scheduling
- Reuses `scripts_common.sh` helpers (`_resolve_profile_id`, `radarr_api_get`, `check_needed_executables`, `debug_log`)

### 2.4 File handling: Let Radarr manage

**Decision:** Same as reverse script — after switching, let Radarr handle file management. Next search finds Remux, downloads, replaces WebDL.

### 2.5 Search trigger

**Decision:** `TRIGGER_SEARCH=true` by default. After switching, queue `MoviesSearch` for switched movies. Consistent with both switch scripts.

## 3. Script: `radarr/fix_quality_profiles.sh`

### 3.1 Purpose

Batch job that:
1. Resolves wrong/correct profile IDs by name
2. Fetches all movies
3. Filters to movies with `physicalRelease` set and `qualityProfileId == wrong profile`
4. Switches those to the correct profile (dry-run by default)
5. Triggers search when `TRIGGER_SEARCH=true`

### 3.2 Behavior modes

| Mode | Trigger | Effect |
|------|---------|--------|
| Dry-run | Default or `-n` / `--dry-run` | Print candidates, no API mutations |
| Apply | `--apply` | Actually switch profiles |
| JSON | `-j` / `--json` | Machine-readable JSON output |
| Quiet | `-q` / `--quiet` | Only errors and counts |
| Debug | `-d` / `--debug` | Debug logging to stderr |

**Mode precedence:** `--apply` overrides `DRY_RUN` config. `--json` overrides `--quiet`. Same as switch scripts.

### 3.3 Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success (including 0 candidates) |
| 1 | API or configuration error |
| 127 | Missing executable dependency |

## 4. Configuration

Sourced from `scripts.conf` via `scripts_common.sh`. Script-specific defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `WRONG_PROFILE_NAME` | `[SQP] SQP-3 (Audio)` | Profile to detect and fix |
| `CORRECT_PROFILE_NAME` | `SQP-3-RemuxOnly` | Profile to switch to |
| `DRY_RUN` | `true` | Preview mode; `--apply` or `DRY_RUN=false` to execute |
| `MAX_SWITCH_PER_RUN` | `0` | Max movies per run, `0` = unlimited |
| `TRIGGER_SEARCH` | `true` | Queue `MoviesSearch` after switching |
| `DEBUG` | `false` | Debug logging |

## 5. Algorithm

### 5.1 Profile resolution

```
wrong_id   = _resolve_profile_id(WRONG_PROFILE_NAME)
correct_id = _resolve_profile_id(CORRECT_PROFILE_NAME)
error+exit if either fails or both ids are equal
```

### 5.2 Candidate matching

```
all_movies = GET /api/v3/movie

candidates = all_movies[]
    | select(.physicalRelease != null
        and .qualityProfileId == wrong_id)
    | {id, title, year, physicalRelease, qualityProfileId}
```

### 5.3 Switch execution

For each candidate (respecting `MAX_SWITCH_PER_RUN`, `sleep 0.5` between calls):

```
PUT /api/v3/movie/editor
body: {"movieIds": [id], "qualityProfileId": correct_id}
```

### 5.4 Search trigger

If `TRIGGER_SEARCH=true` and switched list non-empty:

```
POST /api/v3/command
body: {"name": "MoviesSearch", "movieIds": switched_ids}
```

## 6. Output Format

### 6.1 Pretty table (default)

```
Quality Profile Fix
===================

Wrong profile: [SQP] SQP-3 (Audio) (id: X)
Correct profile: SQP-3-RemuxOnly (id: Y)

Movie                        Phys Release  Current          -> Target
-----                        ------------  -------          --------
Movie Title (2024)           2026-03-14    [SQP] SQP-3 (Audio) -> SQP-3-RemuxOnly

DRY-RUN: 5 movies would switch. Run with --apply to execute.
```

Apply mode:

```
APPLY: Switched 5 movies to SQP-3-RemuxOnly
QUEUED: 5 movies sent for search
```

### 6.2 JSON mode (`--json`)

```json
{
  "wrong_profile": {"id": 3, "name": "[SQP] SQP-3 (Audio)"},
  "correct_profile": {"id": 4, "name": "SQP-3-RemuxOnly"},
  "candidates": [
    {"id": 123, "title": "Movie Title", "year": 2024, "physicalRelease": "2026-03-14T00:00:00Z", "qualityProfileId": 3}
  ],
  "candidate_count": 5,
  "switched_count": 5,
  "searched_count": 5,
  "search_triggered": true,
  "dry_run": false
}
```

## 7. Edge Cases

| Edge case | Handling |
|-----------|----------|
| No candidates | "No candidates to fix." — success, exit 0 |
| Wrong and correct profiles resolve to same id | Error, exit 1 |
| Profile name not found | Error with available profiles list, exit 1 |
| API unreachable | Error, exit 1 |
| Movie already on correct profile | Excluded by filter |
| Movie has WebDL file when switching | Let Radarr manage (next search upgrades) |
| `MAX_SWITCH_PER_RUN` reached mid-batch | Stop, report partial count |
| Search command fails | Warning, continue — profiles already fixed |
| Physical release removed after being set | Not selected (`physicalRelease == null`) |

## 8. Scheduling (user responsibility)

```cron
0 7 * * 0 /path/to/radarr/fix_quality_profiles.sh --apply >> /var/log/quality-profile-fix.log 2>&1
```

## 9. Dependencies

- `curl` — API calls
- `jq` 1.6+ — JSON processing
- Standard POSIX `sh` — runtime

## 10. Project conventions (must follow)

- Shebang: `#!/usr/bin/env sh`
- `# shellcheck disable=SC3043` for `local`
- Changelog version blocks (newest first)
- `scripts_common.sh` for API helpers
- `load_config "$(dirname "$0")/connect"` for config
- Local vars prefixed with underscore
- Errors to stderr
- Quote all variable expansions
- `printf` for formatted output, `echo` for simple strings
- Indent 4 spaces, 100-char soft line limit
