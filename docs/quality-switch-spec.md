# Auto Quality Profile Switch — Specification

## 1. Problem Statement

Radarr profiles can pin movies to Remux-only quality. As studios increasingly skip physical (disc) releases, some movies never get a Remux source. Those movies stall permanently — never upgraded, never downloaded. The library accumulates "dead" entries that will never be satisfied.

**Goal:** Automatically detect movies unlikely to ever get a physical release and switch them to a quality profile that allows WebDL.

**See also:** `quality-switch-reverse-spec.md` for the reverse script that switches movies back when physical releases appear.

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

**Mode precedence:**

1. `--apply` flag always overrides `DRY_RUN` config. This means:
   - `DRY_RUN=true` in conf + `--apply` flag → **applies** (flag wins)
   - `DRY_RUN=false` in conf + no flag → **applies** (conf says go)
   - `DRY_RUN=false` in conf + `--dry-run` flag → **dry-run** (flag wins)
2. `--json` takes precedence over `--quiet` for output format. If both passed, JSON wins.
3. `--apply` + `--json` → switches profiles AND outputs JSON with results.

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
```

The IQR filter and percentile computation happen in a single jq pass. Pass `P_VALUE` and `MIN_SAMPLE` as jq args:

```jq
# IQR filter function: removes outliers using 1.5*IQR rule
def iqr_filter:
    if length == 0 then []
    else
        sort as $sorted
        | (($sorted | length) * 0.25 | floor) as $q1_idx
        | (($sorted | length) * 0.75 | floor) as $q3_idx
        | $sorted[$q1_idx] as $q1
        | $sorted[$q3_idx] as $q3
        | ($q3 - $q1) as $iqr
        | ($q1 - 1.5 * $iqr) as $lower
        | ($q3 + 1.5 * $iqr) as $upper
        | [.[] | select(. >= $lower and . <= $upper)]
    end;

# Build gap array: movies with both digital + physical, gap in days
[.[] | select(.digitalRelease != null and .physicalRelease != null)
 | ((.physicalRelease | fromdateiso8601) - (.digitalRelease | fromdateiso8601)) / 86400] as $gaps

# If sample too small, return null (caller uses FALLBACK_THRESHOLD)
| if ($gaps | length) < ($min_sample | tonumber) then
    {threshold: null, sample_size: ($gaps | length), used_fallback: true}

# Otherwise: IQR filter, then percentile on filtered
else
    ($gaps | iqr_filter | sort) as $filtered
    | ($filtered[(($filtered | length) * ($p_value | tonumber)) | floor]) as $p_val
    | {threshold: $p_val, sample_size: ($gaps | length), filtered_size: ($filtered | length), used_fallback: false}
end
```

**Percentile approximation:** Uses index-based percentile: `sorted[floor(length * p)]`. With 30 samples at P95, index 28 = ~96.7th percentile (slightly conservative). This is acceptable — the threshold is clamped by MIN/MAX anyway.

**Clamping (in shell, not jq):**
```sh
_threshold=$(printf '%s' "${_threshold_json}" | jq -r '.threshold')
_used_fallback=$(printf '%s' "${_threshold_json}" | jq -r '.used_fallback')

if [ "${_used_fallback}" = "true" ] || [ -z "${_threshold}" ] || [ "${_threshold}" = "null" ]
then
    _threshold="${FALLBACK_THRESHOLD}"
fi

# Clamp to [MIN_THRESHOLD, MAX_THRESHOLD]
[ "${_threshold}" -lt "${MIN_THRESHOLD}" ] && _threshold="${MIN_THRESHOLD}"
[ "${_threshold}" -gt "${MAX_THRESHOLD}" ] && _threshold="${MAX_THRESHOLD}"
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
    if movie.hasFile == true:
        skip  # Already has a downloaded file
    if movie.monitored == false:
        skip  # Unmonitored — search won't trigger anyway

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

**Success criteria:** HTTP 200 (Accepted) response with a JSON body containing a `jobId` field. Any other HTTP status or curl failure = error. Log the response body on failure for diagnosis.

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
- Define default variables (section 4.2)
- **Update `radarr/connect/scripts.conf.sample`** with all new config variables from section 4.2, commented out with defaults. Project convention requires sample files to document all config variables.

### Phase 2: Profile resolution (1 step)

- Implement `_resolve_profile_id(name)`:
  - `GET /api/v3/qualityProfile`
  - `jq` to find profile by name
  - Exit with error if not found
- Validate both source and target profiles exist before proceeding

### Phase 3: Threshold computation (1 step)

- Implement the jq query from section 5.1 (inline above — do not reference external files)
- Pass `P_VALUE` and `MIN_SAMPLE` as `--arg` to jq
- Parse result: extract `threshold`, `sample_size`, `used_fallback`
- Apply fallback logic if `used_fallback == true`
- Clamp to `[MIN_THRESHOLD, MAX_THRESHOLD]` in shell
- Log: computed P-value, sample size, outliers removed, final threshold

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
  - Per-movie candidate list using `printf` with fixed-width format specifiers (e.g., `%-40s %8s %-20s %s`). Do NOT use `column -t` — it is not available on all systems (notably some FreeBSD/minimal Linux images).
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
| Movie already has a downloaded file (`hasFile == true`) | Skip (already has a release) |
| Movie is unmonitored (`monitored == false`) | Skip (search won't trigger) |
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

## 11. Migration Mode (`--migrate`)

### 11.1 Purpose

One-time migration tool to fix existing movies in the library that are on Remux-only profiles but should have been switched to WebDL. Unlike the normal mode (which targets movies without files), migration mode targets movies that already have downloaded files.

**Use case:** After setting up the script, run `--migrate` once to clean up the existing backlog of "dead" movies that will never get a Remux release.

### 11.2 Behavior

| Mode | Trigger | Effect |
|------|---------|--------|
| Dry-run (default) | `--migrate` | Print candidates, no API mutations |
| Apply | `--migrate --apply` | Switch WebDL files, log non-WebDL files |
| JSON | `--migrate --json` | Output machine-readable JSON |
| Quiet | `--migrate --quiet` | Only print errors and counts |

**Key differences from normal mode:**
- Targets movies with `hasFile == true` (instead of `false`)
- Checks file quality source before switching
- WebDL/WebRip files → switch profile + add tag
- Non-WebDL files → log to stderr for manual review
- Never triggers search (manual review needed)
- Run once, then use normal mode for ongoing maintenance

### 11.3 Candidate matching

```
candidates = []
for movie in all_movies:
    if movie.digitalRelease == null:
        skip
    if movie.physicalRelease != null:
        skip
    if movie.qualityProfileId != source_id:
        skip
    if movie.hasFile == false:
        skip  # Migration mode: only movies with files
    if movie.monitored == false:
        skip
    
    waiting_days = (now - movie.digitalRelease) in days
    if waiting_days < threshold:
        skip
    
    # Check file quality
    movie_file = GET /api/v3/moviefile/{movie.movieFileId}
    quality_source = movie_file.quality.quality.source
    
    if quality_source in ["webdl", "webrip"]:
        candidates.append({
            action: "switch",
            movie: movie,
            quality: quality_source
        })
    else:
        candidates.append({
            action: "log",
            movie: movie,
            quality: quality_source
        })
```

### 11.4 Quality source classification

| Source | Action | Reason |
|--------|--------|--------|
| `webdl` | Switch | Already a WebDL release, just wrong profile |
| `webrip` | Switch | Similar to WebDL, acceptable |
| `bluray` | Log | Physical release exists, needs manual review |
| `remux` | Log | Already Remux, might be intentional |
| `hdtv` | Log | Broadcast recording, needs review |
| `dvd` | Log | DVD source, needs review |
| Other | Log | Unknown source, needs review |

### 11.5 Output format

**Dry-run:**
```
Auto Quality Profile Switch (Migration Mode)
=============================================

Threshold: P95 = 265d (based on 1921 movies with both dates)
Source profile: Remux-2160p (id: 5)
Target profile: WebDL-2160p (id: 7)

Movies to switch (WebDL/WebRip):
  The Matrix Resurrections (2021) — WEBDL-2160p — 487d
  ...

Movies needing manual review (non-WebDL):
  WARN: [bluray] Dune (2021) — Bluray-2160p — 1205d
  WARN: [remux] Tenet (2020) — Remux-2160p — 1580d
  ...

DRY-RUN: 42 movies would switch, 5 need manual review.
```

**Apply:**
```
APPLY: Switched 42 movies to WebDL-2160p
TAGS: Added auto-switched tag to 42 movies
WARN: 5 movies need manual review (non-WebDL files):
  WARN: [bluray] Dune (2021) — Bluray-2160p
  WARN: [remux] Tenet (2020) — Remux-2160p
  ...
```

### 11.6 Implementation notes

- Add `--migrate` to CLI flags
- Modify candidate matching jq to accept `hasFile` as parameter
- After candidate matching, fetch moviefile for each candidate
- Classify by quality source
- For WebDL/WebRip: switch profile + add tag (same as normal mode)
- For others: log to stderr with quality source
- No search trigger in migration mode
- Changelog: v0.4.0

## 12. Project conventions (must follow)

- Shebang: `#!/usr/bin/env sh`
- `# shellcheck disable=SC3043` for `local`
- Changelog version blocks (newest first)
- `scripts_common.sh` for API helpers
- `load_config "$(dirname "$0")/connect"` for config — note that `load_config` accepts an optional config directory as `$1`, defaulting to `$(dirname "$0")`. This script lives in `radarr/` (not `radarr/connect/`), so it MUST pass the path: `load_config "$(dirname "$0")/connect"`. See `radarr/research/release_date_stats.sh` for a working example of this pattern.
- Local vars prefixed with underscore
- Errors to stderr
- Quote all variable expansions
- `printf` for formatted output, `echo` for simple strings
- Indent 4 spaces, 100-char soft line limit
