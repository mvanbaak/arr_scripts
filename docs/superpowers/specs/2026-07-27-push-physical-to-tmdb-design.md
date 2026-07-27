# push_physical_to_tmdb.sh — Design Spec

## Problem

`fetch_physical_dates.sh` finds physical release dates on Blu-ray.com that Radarr lacks, but TMDB has no API write endpoint for movie metadata. Dates must be submitted manually via TMDB website edit forms. This script automates that submission.

## Approach

Two-phase cookie-based authentication (like yt-dlp):

1. **Playwright login** — runs once on dev machine with display, solves AWS WAF JS challenge, exports session cookies to Netscape format file (`~/.tmdb_cookies.txt`)
2. **curl push script** — reads cookie file, makes direct API calls to TMDB. Runs anywhere (FreeBSD, headless server).

### Why two phases?

TMDB login POST is intercepted by AWS WAF (`x-amzn-waf-action: challenge`). curl can't solve the JS challenge. Playwright (headed, with Xvfb) can. Once authenticated, the session cookie works for curl.

## Data Flow

```
Phase 1: tmdb_login.sh (run once, on machine with display)
  Playwright → login → export cookies → ~/.tmdb_cookies.txt

Phase 2: push_physical_to_tmdb.sh (runs anywhere, cron-friendly)
  fetch_physical_dates.sh --json --quiet
    → JSON with {tmdb_id, physical_date, title, ...}
    → piped to push_physical_to_tmdb.sh
    → for each movie:
        curl with ~/.tmdb_cookies.txt
        POST /movie/{tmdb_id}/remote/release_information
          with JSON body + CSRF token
        Log success/failure
```

## Scripts

### tmdb_login.sh (Phase 1)

Standalone Node.js script. Uses Playwright to:
1. Open Chromium (headed, needs DISPLAY or Xvfb)
2. Navigate to `https://www.themoviedb.org/login`
3. Fill `#username`, `#password`, click `#login_button`
4. Wait for navigation to complete
5. Extract all cookies from browser context
6. Write to `~/.tmdb_cookies.txt` in Netscape format

**Output:** `~/.tmdb_cookies.txt` (shared with yt-dlp if needed)

### push_physical_to_tmdb.sh (Phase 2)

Shell script. Accepts:
- **Args mode:** `push_physical_to_tmdb.sh <tmdb_id> <date> [title]`
- **Pipe mode:** `fetch_physical_dates.sh --json --quiet | push_physical_to_tmdb.sh`

#### Authentication

1. Check `~/.tmdb_cookies.txt` exists, else error
2. Extract CSRF token from edit page: `GET /movie/{tmdb_id}/edit?active_nav_item=release_information`
3. Extract `authenticity_token` from HTML

#### Release Date Submission

### Endpoint

```
POST https://www.themoviedb.org/movie/{tmdb_id}/remote/release_information?translate=false&timezone=UTC
```

### Headers

```
Content-Type: application/x-www-form-urlencoded
X-CSRF-Token: {authenticity_token}
X-Requested-With: XMLHttpRequest
```

### Body

```
data={"iso_3166_1":"US","iso_639_1":"en","release_date":"2026-01-15","certification":"","type":5,"note":"Physical release"}
```

### Release Type Values

| Value | Type |
|-------|------|
| 1 | Premiere |
| 2 | Limited |
| 3 | Theatrical |
| 4 | Digital |
| 5 | Physical |
| 6 | TV |
| 7 | Total |

Default: `5` (Physical)

## Flags

### push_physical_to_tmdb.sh

| Flag | Description |
|------|-------------|
| `--dry-run` | Show what would be submitted, don't POST |
| `--debug` | Verbose logging |
| `--country <code>` | ISO 3166-1 country code (default: US) |
| `--language <code>` | ISO 639-1 language code (default: en) |
| `--type <N>` | Release type 1-7 (default: 5) |
| `--note <text>` | Note field (default: "Physical release") |
| `--cookies <file>` | Cookie file path (default: ~/.tmdb_cookies.txt) |

### tmdb_login.sh

| Flag | Description |
|------|-------------|
| `--cookies <file>` | Output cookie file path (default: ~/.tmdb_cookies.txt) |
| `--debug` | Verbose logging |

## Config

`scripts.conf` needs `TMDB_USERNAME` and `TMDB_PASSWORD` for `tmdb_login.sh`.

`push_physical_to_tmdb.sh` reads credentials from cookie file only (no config needed).

## Dependencies

- `tmdb_login.sh`: Playwright + Chromium (one-time, on dev/display machine)
- `push_physical_to_tmdb.sh`: curl, jq, grep, sed (all POSIX, runs anywhere)

## Edge Cases

- **Cookie file missing:** Exit with error, run `tmdb_login.sh` first
- **Cookies expired:** Detect 401, suggest re-running `tmdb_login.sh`
- **CSRF token missing:** Re-fetch page and retry
- **Rate limiting:** 1s sleep between movies in pipe mode
- **Duplicate release date:** TMDB may reject or ignore; log response
- **Invalid TMDB ID:** Skip with warning
- **Date format:** Accept YYYY-MM-DD, convert if needed

## Output

### Success
```
[1/5] Supergirl (2026) → TMDB #123456: 2026-09-08 ✓
```

### Failure
```
[2/5] Batman (2025) → TMDB #789012: ✗ Cookies expired, re-run tmdb_login.sh
```

### Dry-run
```
[1/5] Supergirl (2026) → TMDB #123456: 2026-09-08 (dry-run)
```

## Example Usage

```sh
# Step 1: Login (run once, on machine with display)
./radarr/tmdb_login.sh

# Step 2: Push dates
./radarr/push_physical_to_tmdb.sh 123456 2026-09-08 "Supergirl"

# Pipeline from fetch_physical_dates.sh
./radarr/fetch_physical_dates.sh --json --quiet | ./radarr/push_physical_to_tmdb.sh

# Dry-run
./radarr/fetch_physical_dates.sh --json --quiet | ./radarr/push_physical_to_tmdb.sh --dry-run

# Custom country/type
./radarr/push_physical_to_tmdb.sh 123456 2026-09-08 --country GB --type 3
```
