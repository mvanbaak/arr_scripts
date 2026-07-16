# Auto Quality Profile Switch (Reverse) — Specification

## 1. Problem Statement

The forward switch script (`auto_quality_switch.sh`) moves movies from Remux-only to WebDL profiles when no physical release appears within a statistical threshold. However, some of these movies later receive physical release dates in Radarr (e.g., boutique labels, delayed disc announcements). These movies remain on WebDL profiles indefinitely, missing the opportunity to upgrade to Remux when physical media becomes available.

**Goal:** Automatically detect movies previously switched to WebDL that now have physical release dates, and switch them back to Remux-only profiles.

## 2. Design Decisions

### 2.1 Detection method: Radarr tags

**Decision:** Use a Radarr tag (`auto-switched`) to track movies switched by the forward script.

**Rationale:**
- Clean, idempotent, queryable via API
- No false positives (only movies explicitly switched by our script get tagged)
- Survives restarts, DB migrations, script updates
- No external state files to manage

**Alternatives considered:**
- Fuzzy match (profile == TARGET + physicalRelease set): Rejected — can't distinguish "we switched" from "always was"
- State file: Rejected — breaks on Radarr DB restore, adds file management overhead

### 2.2 Forward script dependency

**Prerequisite:** The forward script (`auto_quality_switch.sh`) must be modified to add the `auto-switched` tag when switching movies to the TARGET profile.

**Forward script changes:**
1. Add `AUTO_SWITCH_TAG` config variable (default: `auto-switched`)
2. On script startup, create tag if it doesn't exist: `POST /api/v3/tag` with `{"label": "auto-switched"}`
3. After each successful profile switch (inside the per-movie loop), add tag to movie: `PUT /api/v3/movie/{id}` with updated tags array
4. If profile switch fails, tag is not added (per-movie atomicity)

**Tag creation flow:**
```
# Run once at script startup
tags = GET /api/v3/tag
tag_id = tags[where label == AUTO_SWITCH_TAG].id

if tag_id == null:
    response = POST /api/v3/tag
        body: {"label": "auto-switched"}
    tag_id = response.id
```

**Tag addition flow (per-movie, after successful switch):**
```
# Fetch movie's current tags
movie = GET /api/v3/movie/{id}

# Add auto-switched tag (preserve existing tags)
PUT /api/v3/movie/{id}
    body: {"tags": movie.tags + [tag_id]}
```

**Note:** Profile switch and tag addition are two separate API calls, not truly atomic. If tag addition fails after a successful profile switch, the movie will be switched but untagged. The reverse script will not pick it up (no false positives). The forward script can log the error for manual remediation.

### 2.3 Script structure: Separate script

**Decision:** Implement as `radarr/auto_quality_switch_reverse.sh`, separate from the forward script.

**Rationale:**
- Forward and reverse have different cadence (daily vs weekly)
- Keeps each script simple and focused
- Shared config via `scripts_common.sh` avoids duplication
- Independent scheduling via cron

**Alternatives considered:**
- Same script with `--reverse` flag: Rejected — adds complexity, harder to schedule independently
- Both directions in one pass: Rejected — too aggressive, no separate control

### 2.4 File handling: Let Radarr manage

**Decision:** When switching back, if movie has a WebDL file, let Radarr handle file management.

**Rationale:**
- Radarr automatically detects profile mismatch
- Next search finds Remux release, downloads it, deletes WebDL
- One wasted WebDL download is acceptable — it auto-corrects
- Simpler implementation, no manual file deletion

**Alternatives considered:**
- Delete file before switching: Rejected — aggressive, wastes bandwidth if Remux not available
- Skip if hasFile==true: Rejected — defeats the purpose

### 2.5 Search trigger: Always search

**Decision:** After switching back to Remux-only, always trigger search for Remux.

**Rationale:**
- User wants Remux upgrade to happen promptly
- Consistent with forward script behavior
- Radarr handles queue management

## 3. Script: `radarr/auto_quality_switch_reverse.sh`

### 3.1 Purpose

Weekly cron job that:
1. Fetches all movies from Radarr API
2. Filters to movies tagged with `auto-switched`
3. Identifies movies where:
   - `physicalRelease` is now set (was previously null)
   - Current `qualityProfileId` matches the TARGET profile (WebDL)
4. Switches those movies back to the SOURCE profile (Remux-only)
5. Removes the `auto-switched` tag
6. Triggers search for Remux release

### 3.2 Behavior modes

| Mode | Trigger | Effect |
|------|---------|--------|
| Dry-run | Default or `-n` / `--dry-run` | Print candidates, no API mutations |
| Apply | `--apply` | Actually switch profiles |
| JSON | `-j` / `--json` | Output machine-readable JSON |
| Quiet | `-q` / `--quiet` | Only print errors and counts, no per-movie list |

**Mode precedence:** Same as forward script (see `quality-switch-spec.md` section 3.2).

### 3.3 Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success (no changes needed in dry-run) |
| 0 | Success (N movies switched in apply mode) |
| 1 | API error or configuration error |
| 127 | Missing executable dependency |

## 4. Configuration

### 4.1 From `scripts.conf`

The script sources `scripts_common.sh` and reads these existing settings:

```sh
RADARR_API_URL="http://ip:7878/api/v3"
RADARR_API_KEY="your_api_key"
```

### 4.2 Script-specific defaults (can be overridden in `scripts.conf`)

| Variable | Default | Description |
|----------|---------|-------------|
| `SWITCH_TO_PROFILE_NAME` | `Remux-2160p` | Profile to switch movies back to (Remux-only). Must match forward script's `SOURCE_PROFILE_NAME`. |
| `SWITCH_FROM_PROFILE_NAME` | `WebDL-2160p` | Profile to match candidates for reverse switch (WebDL). Must match forward script's `TARGET_PROFILE_NAME`. |
| `AUTO_SWITCH_TAG` | `auto-switched` | Radarr tag used to track movies switched by forward script. |
| `DRY_RUN` | `true` | Default preview mode. Set `false` in `scripts.conf` or pass `--apply` to execute switches. |
| `MAX_SWITCH_PER_RUN` | `0` | Max movies to switch per run. `0` = unlimited. Limits batch size to avoid hammering API. |
| `TRIGGER_SEARCH` | `true` | After switching, call `POST /api/v3/command` to queue `MoviesSearch` for switched movies. Set `false` to only switch profiles. |

### 4.3 Example `scripts.conf` overrides

```sh
# Auto quality switch (reverse) settings
# These should match the forward script's values
SWITCH_TO_PROFILE_NAME="Remux-2160p"
SWITCH_FROM_PROFILE_NAME="WebDL-2160p"
AUTO_SWITCH_TAG="auto-switched"
# Uncomment to allow switches without --apply flag:
# DRY_RUN=false
# Safety limit per run:
# MAX_SWITCH_PER_RUN=50
# Uncomment to skip search after switch:
# TRIGGER_SEARCH=false
```

## 5. Algorithm

### 5.1 Tag resolution

```
tags = GET /api/v3/tag
auto_switch_tag_id = tags[where label == AUTO_SWITCH_TAG].id
```

If tag not found, create it:
```
POST /api/v3/tag
body: {"label": "auto-switched"}
```

### 5.2 Candidate matching

**Note:** Radarr API does not support tag-based filtering via query parameters. Fetch all movies and filter in jq.

```
# Fetch all movies
all_movies = GET /api/v3/movie

# Filter to tagged movies with physical release
candidates = []
for movie in all_movies:
    if auto_switch_tag_id not in movie.tags:
        skip  # Not tagged by our script
    if movie.physicalRelease == null:
        skip  # Still no physical release
    if movie.qualityProfileId != switch_from_id:
        skip  # Not on WebDL profile (already switched back?)
    
    candidates.append(movie)
```

### 5.3 Profile switch + tag removal

For each candidate:
```
# Switch profile
PUT /api/v3/movie/editor
body: {
    "movieIds": [candidate.id],
    "qualityProfileId": switch_to_id
}

# Remove auto-switched tag (keep other tags)
movie = GET /api/v3/movie/{id}
PUT /api/v3/movie/{id}
body: {
    "tags": [movie.tags[] | select(. != auto_switch_tag_id)]
}
```

**Tag removal approach:** The movie editor endpoint doesn't support tag operations directly. Fetch the movie's current tags, filter out the `auto-switched` tag, and update via the movie update endpoint.

### 5.4 Search trigger

After all profile switches, if `TRIGGER_SEARCH=true` and switched list non-empty:

```
POST /api/v3/command
body: {
    "name": "MoviesSearch",
    "movieIds": switched_ids
}
```

Same as forward script — Radarr queues search tasks for Remux releases.

## 6. Output Format

### 6.1 Pretty table (default)

```
Auto Quality Profile Switch (Reverse)
=====================================

Candidates: 5 movies with physical release now available

Movie                        Physical Release  Current       -> Target
-----                        ----------------  -------       --------
The Matrix Resurrections     2022-04-26        WebDL-2160p   -> Remux-2160p
...

DRY-RUN: 5 movies would switch. Run with --apply to execute.
```

Or in apply mode:

```
APPLY: Switched 5 movies to Remux-2160p
TAGS: Removed auto-switched tag from 5 movies
QUEUED: 5 movies sent for search
```

### 6.2 JSON mode (`--json`)

```json
{
  "switch_to_profile": {"id": 5, "name": "Remux-2160p"},
  "switch_from_profile": {"id": 7, "name": "WebDL-2160p"},
  "tag": {"id": 12, "label": "auto-switched"},
  "candidates": [
    {
      "id": 123,
      "title": "The Matrix Resurrections",
      "year": 2021,
      "physicalRelease": "2022-04-26T00:00:00Z",
      "qualityProfileId": 7
    }
  ],
  "candidate_count": 5,
  "switched_count": 5,
  "tags_removed": 5,
  "searched_count": 5,
  "search_triggered": true,
  "dry_run": false
}
```

## 7. Implementation Plan

### Phase 1: Forward script tag support (prerequisite)

This phase must be completed before the reverse script can function. The forward script must tag movies it switches so the reverse script can identify them.

**Changes to `radarr/auto_quality_switch.sh`:**
- Add `AUTO_SWITCH_TAG` config variable (default: `auto-switched`)
- Add tag creation at script startup: check if tag exists, create if not
- After each successful profile switch (inside the per-movie loop), add tag to movie via `PUT /api/v3/movie/{id}`
- If tag addition fails, log warning but continue (movie is switched, just untagged)
- Update changelog to v0.3.0
- Update `scripts.conf.sample` with new config variable

### Phase 2: Reverse script scaffold (1 step)

- Create `radarr/auto_quality_switch_reverse.sh`
- Changelog header following project convention
- Source `scripts_common.sh`, call `load_config`
- Define default variables (section 4.2)
- Update `radarr/connect/scripts.conf.sample` with reverse script config

### Phase 3: Tag resolution (1 step)

- Implement tag lookup/creation
- Fetch tag ID from Radarr API
- Create tag if not found

### Phase 4: Candidate matching (1 step)

- Fetch all movies (API doesn't support tag filtering)
- Filter by tag in jq
- Filter to those with `physicalRelease` set
- Filter to those on SWITCH_FROM profile
- Output candidate list

### Phase 5: Switch execution (1 step)

- Switch profile via movie editor API
- Remove tag via movie update API
- Rate-limit with `sleep 0.5` between calls
- Respect `MAX_SWITCH_PER_RUN`

### Phase 6: Search trigger (1 step)

- Same as forward script
- POST `/api/v3/command` with `MoviesSearch`

### Phase 7: Output (1 step)

- Pretty table printing (same conventions as forward script)
- JSON output via `--json` flag

### Phase 8: Documentation (1 step)

- Update `docs/quality-switch-spec.md` to reference reverse script
- Add changelog entries
- Update `scripts.conf.sample` with all config variables

### Phase 9: Verification (1 step)

- Run `shellcheck -e SC3043 -s sh`
- Test with `DRY_RUN=true` on a real Radarr instance
- Verify tag creation and movie tagging
- Verify reverse switch and tag removal

## 8. Edge Cases

| Edge case | Handling |
|-----------|----------|
| Tag doesn't exist | Create it automatically on first run |
| Movie has WebDL file when switching back | Let Radarr handle — next search finds Remux, deletes WebDL |
| Movie was manually switched (no tag) | Not affected — only tagged movies are candidates |
| Movie was switched but tag was removed | Not affected — can't be identified |
| Movie on TARGET profile but never switched by us | Not affected — no tag |
| Physical release date removed after being set | Won't be selected (physicalRelease == null) |
| API unreachable | Print error, exit 1 |
| All candidates already switched | "0 candidates" — success |
| `MAX_SWITCH_PER_RUN` reached mid-batch | Stop, report partial switch count |
| Search command fails | Log warning, continue — movies are already switched |
| Tag addition fails after profile switch | Log warning, continue — movie is switched but untagged |

## 9. Scheduling (user responsibility)

Recommended crontab (weekly, Sunday at 7am):

```cron
0 7 * * 0 /path/to/radarr/auto_quality_switch_reverse.sh --apply >> /var/log/quality-switch-reverse.log 2>&1
```

Or run in dry-run mode first:

```cron
0 7 * * 0 /path/to/radarr/auto_quality_switch_reverse.sh >> /var/log/quality-switch-reverse-preview.log 2>&1
```

## 10. Dependencies

- `curl` — API calls
- `jq` 1.6+ — JSON processing
- Standard POSIX `sh` — runtime
- Radarr API access with key configured

## 11. Project conventions (must follow)

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
