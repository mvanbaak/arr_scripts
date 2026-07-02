# Auto Quality Profile Switch — Specification

## 1. Problem Statement

Radarr profiles can pin movies to Remux-only quality. As studios increasingly skip physical (disc) releases, some movies never get a Remux source. Those movies stall permanently — never upgraded, never downloaded. The library accumulates "dead" entries that will never be satisfied.

**Goal:** Automatically detect movies unlikely to ever get a physical release and switch them to a quality profile that allows WebDL.

## 2. Research Summary

Empirical analysis of 2,631 movies with cinema dates yields:

### 2.1 Physical release timing

| Metric | Value | Meaning |
|--------|-------|---------|
| P50 (median) | 54 days | Half of physical releases within 54 days of web |
| P90 | 195 days | 90% within ~6.5 months |
| P95 | 265 days | 95% within ~9 months |
| P99 | 545 days | 99% within ~18 months |
| Sample | 1,921 movies | Movies with both web + physical dates |
| Outliers removed | 407 | Bogus dates filtered via IQR |

**Interpretation:** If a movie has no physical release 265 days after its web/streaming date, there is a ~5% chance a physical release will still come later. This is the recommended threshold.

### 2.2 Current backlog

Movies with cinema + web but no physical: **334**
Of those, **~290** have waited longer than 265 days.

These are immediate candidates for profile switching.

### 2.3 Assumptions and caveats

- Data comes from TMDB via Radarr's metadata. TMDB may have incomplete or incorrect dates.
- `fromdateiso8601` in jq parses ISO 8601 date strings. Bogus epoch-zero dates or year-1900 values produce extreme outliers; IQR filtering catches most of these.
- The P95 threshold recomputes from your library on each run, adapting to your collection's distribution.
- Some legitimate physical releases genuinely take longer than 265 days (e.g., boutique labels, limited editions) — the 5% false positive rate accounts for these.

## 3. Script: `radarr/auto_quality_switch.sh`

### 3.1 Purpose

Daily cron job that:
1. Fetches all movies from Radarr API
2. Computes the dynamic P95 threshold from movies with both web + physical dates
3. Identifies movies where:
   - `digitalRelease` exists and `physicalRelease` is null
   - Days since `digitalRelease` > computed threshold
   - Current `qualityProfileId` matches the source profile
4. Optionally switches those movies to the target quality profile
5. Reports what happened

### 3.2 Behavior modes

| Mode | Trigger | Effect |
|------|---------|--------|
| Dry-run | Default or `-n` / `--dry-run` | Print candidates, no API mutations |
| Apply | `--apply` | Actually switch profiles |
| JSON | `-j` / `--json` | Output machine-readable JSON |
| Quiet | `-q` / `--quiet` | Only print errors and counts, no per-movie list |

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
| `SOURCE_PROFILE_NAME` | `Remux-2160p` | Profile name to match movies that need switching. Case-sensitive, must match Radarr exactly. |
| `TARGET_PROFILE_NAME` | `WebDL-2160p` | Profile name to switch matched movies to. Case-sensitive, must match Radarr exactly. |
| `P_VALUE` | `0.95` | Percentile used as threshold (0.0–1.0). P95 = 95% of physical releases happen within this window. Lower = more aggressive; higher = more conservative. |
| `MIN_SAMPLE` | `30` | Minimum movies with both web+physical dates needed to compute threshold. Below this, uses `FALLBACK_THRESHOLD`. |
| `FALLBACK_THRESHOLD` | `365` | Hardcoded threshold (days) when sample is too small for reliable percentiles. |
| `MIN_THRESHOLD` | `90` | Floor for computed threshold. Prevents nonsense when data is noisy. |
| `MAX_THRESHOLD` | `730` | Ceiling for computed threshold. Prevents excessively long waits. |
| `DRY_RUN` | `true` | Default preview mode. Set `false` in `scripts.conf` or pass `--apply` to execute switches. |
| `MAX_SWITCH_PER_RUN` | `0` | Max movies to switch per run. `0` = unlimited. Limits batch size to avoid hammering API. |
| `TRIGGER_SEARCH` | `true` | After switching, call `POST /api/v3/command` to queue `MoviesSearch` for switched movies. Set `false` to only switch profiles. |

### 4.3 Example `scripts.conf` overrides

```sh
# Auto quality switch settings
SOURCE_PROFILE_NAME="Remux-2160p"
TARGET_PROFILE_NAME="WebDL-2160p"
P_VALUE=0.95
# Uncomment to allow switches without --apply flag:
# DRY_RUN=false
# Safety limit per run:
# MAX_SWITCH_PER_RUN=50
# Uncomment to skip search after switch:
# TRIGGER_SEARCH=false
```

## 5. Algorithm

### 5.1 Threshold computation

```
all_movies = GET /api/v3/movie

# Filter to movies with both web + physical
gap_array = []
for movie in all_movies:
    if movie.digitalRelease != null AND movie.physicalRelease != null:
        gap = (physicalRelease - digitalRelease) in days
        gap_array.append(gap)

# IQR filter
sorted_gaps = sort(gap_array)
Q1 = sorted_gaps[floor(len * 0.25)]
Q3 = sorted_gaps[floor(len * 0.75)]
IQR = Q3 - Q1
lower = Q1 - 1.5 * IQR
upper = Q3 + 1.5 * IQR
filtered = [g for g in gap_array if lower <= g <= upper]

# Percentile on filtered
sorted_filtered = sort(filtered)
P = sorted_filtered[floor(len * P_VALUE)]

# Clamp
threshold = clamp(P, MIN_THRESHOLD, MAX_THRESHOLD)
```

### 5.2 Candidate matching

```
# Map profile names to IDs
profiles = GET /api/v3/qualityProfile
source_id = profiles[where name == SOURCE_PROFILE_NAME].id
target_id = profiles[where name == TARGET_PROFILE_NAME].id

# Find candidates
candidates = []
for movie in all_movies:
    if movie.digitalRelease == null:
        skip  # No web date to measure from
    if movie.physicalRelease != null:
        skip  # Already has physical
    if movie.qualityProfileId != source_id:
        skip  # Already on a different profile
    if movie.inCinemas == null:
        skip  # No cinema date (pre-release, not relevant)

    waiting_days = (now - movie.digitalRelease) in days

    if waiting_days >= threshold:
        candidates.append(movie)
```

### 5.3 Profile switch

```
switched_ids = []
for candidate in candidates:
    PUT /api/v3/movie/editor
    body: {
        "movieIds": [candidate.id],
        "qualityProfileId": target_id
    }
    switched_ids.append(candidate.id)
```

### 5.4 Search trigger

After all profile switches, if `TRIGGER_SEARCH=true` and `switched_ids` is non-empty:

```
if TRIGGER_SEARCH and len(switched_ids) > 0:
    POST /api/v3/command
    body: {
        "name": "MoviesSearch",
        "movieIds": switched_ids
    }
```

Radarr will queue search tasks for the switched movies. They get picked up by Radarr's built-in search queue and download matching releases — no external tool needed.

**Rate limiting:** The search command is a single API call regardless of how many movies were switched. Radarr handles the queue internally, no need to batch or delay. The initial profile switch calls are already rate-limited via `sleep 0.5` between them per `MAX_SWITCH_PER_RUN`.

### 5.5 Safety guards

1. **Always dry-run first** — default mode shows what would change
2. **Threshold clamping** — computed P95 clamped to `[MIN_THRESHOLD, MAX_THRESHOLD]`
3. **Minimum sample** — below `MIN_SAMPLE` movies with both dates, use `FALLBACK_THRESHOLD`
4. **Batch limiting** — `MAX_SWITCH_PER_RUN` caps API writes per invocation
5. **Profile existence check** — abort if source or target profile not found
6. **No-downgrade guarantee** — only switches from SOURCE → TARGET, never the reverse

## 6. Output Format

### 6.1 Pretty table (default)

```
Auto Quality Profile Switch
===========================
Threshold: P95 = 265 days (based on 1921 movies with both dates)
Source profile: Remux-2160p (id: 5)
Target profile: WebDL-2160p (id: 7)

Movie                        Waiting    Current       → Target
The Matrix Resurrections     487d       Remux-2160p   → WebDL-2160p
...

DRY-RUN: 42 movies would switch. Run with --apply to execute.
```

Or in apply mode:

```
APPLY: Switched 42 movies to WebDL-2160p
QUEUED: 42 movies sent for search
Errors: 0
```

### 6.2 JSON mode (`--json`)

```json
{
  "threshold_days": 265,
  "p_value": 0.95,
  "sample_size": 1921,
  "source_profile": {"id": 5, "name": "Remux-2160p"},
  "target_profile": {"id": 7, "name": "WebDL-2160p"},
  "candidates": [
    {"id": 123, "title": "The Matrix Resurrections", "waiting_days": 487, "year": 2021}
  ],
  "candidate_count": 42,
  "switched_count": 42,
  "searched_count": 42,
  "search_triggered": true,
  "dry_run": false
}
```

## 7. Implementation Plan

### Phase 1: Scaffold (1 step)

- Create `radarr/auto_quality_switch.sh`
- Changelog header following project convention
- Source `scripts_common.sh`, call `load_config`
- Define default variables
- Register in `AGENTS.md` if desired

### Phase 2: Profile resolution (1 step)

- Implement `_resolve_profile_id(name)`:
  - `GET /api/v3/qualityProfile`
  - `jq` to find profile by name
  - Exit with error if not found
- Validate both source and target profiles exist before proceeding

### Phase 3: Threshold computation (1 step)

- Implement in jq:
  - `percentiles` function (customizable P value)
  - `iqr_filtered_stats` function (reuse from `release_date_stats.sh`)
  - Gap calculation for movies with both dates
  - Clamp to `[MIN_THRESHOLD, MAX_THRESHOLD]`
  - Fallback if below `MIN_SAMPLE`

### Phase 4: Candidate matching (1 step)

- Implement in a single jq pass:
  - Filter to movies meeting all criteria
  - Compute `waiting_days` using `now`
  - Compare against threshold
  - Output `id`, `title`, `year`, `waiting_days`, `qualityProfileId`

### Phase 5: Switch execution (1 step)

- Implement `switch_movie_profile(movie_id, target_id)`:
  - Dry-run mode: log intent
  - Apply mode: `PUT /api/v3/movie/editor`
  - Rate-limit with `sleep 0.5` between calls
  - Respect `MAX_SWITCH_PER_RUN`
  - Collect switched movie IDs into a list

### Phase 6: Search trigger (1 step)

- After all switches, if `TRIGGER_SEARCH=true` and switched list non-empty:
  - `POST /api/v3/command` with `{"name": "MoviesSearch", "movieIds": [...]}`
  - Validate response for success/error
  - Log number of movies queued for search

### Phase 7: Output (1 step)

- Pretty table printing:
  - Summary header
  - Per-movie candidate list (piped through `column -t` or aligned manually)
  - Final count and mode notice
- JSON output via `--json` flag

### Phase 8: Verification (1 step)

- Run `shellcheck -e SC3043 -s sh`
- Test with `DRY_RUN=true` on a real Radarr instance
- Verify profile resolution with both existing and non-existing profile names
- Verify threshold output matches `release_date_stats.sh` P95 value

## 8. Edge Cases

| Edge case | Handling |
|-----------|----------|
| No movies with both dates | Use `FALLBACK_THRESHOLD`, warn |
| Source profile not found | Print configured name + available profiles, exit 1 |
| Target profile not found | Print configured name + available profiles, exit 1 |
| Source == Target | Print warning, skip all |
| Movie with null digitalRelease or missing dates | Skip (no web date to measure) |
| Movie already on target profile | Skip (already switched) |
| API unreachable | Print error, exit 1 |
| All candidates already switched | "0 candidates" — success |
| P95 computed below `MIN_THRESHOLD` | Clamp to `MIN_THRESHOLD`, log adjustment |
| P95 computed above `MAX_THRESHOLD` | Clamp to `MAX_THRESHOLD`, log adjustment |
| `MAX_SWITCH_PER_RUN` reached mid-batch | Stop, report partial switch count. Still trigger search for movies switched so far. |
| Search command fails (API error) | Log warning, continue. Movies are already switched — they'll be picked up on next Radarr search pass anyway. |
| `TRIGGER_SEARCH=true` but no movies switched | Skip search call entirely. No-op. |

## 9. Scheduling (user responsibility)

Recommended crontab (daily at 6am):

```cron
0 6 * * * /path/to/radarr/auto_quality_switch.sh --apply >> /var/log/quality-switch.log 2>&1
```

Or run in dry-run mode for a week first to observe:

```cron
0 6 * * * /path/to/radarr/auto_quality_switch.sh >> /var/log/quality-switch-preview.log 2>&1
```

## 10. Dependencies

- `curl` — API calls
- `jq` 1.6+ — JSON processing (`fromdateiso8601`, `now`, sort)
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
