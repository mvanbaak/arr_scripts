# download_recap.sh v0.2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix recap quality (single best per season+lang, no overwrites/dups/junk) and storage placement (recap of N in Season N+1 folder).

**Architecture:** Single-file change to `sonarr/connect/download_recap.sh`. Discovery stays; new `select_best_recaps()` awk filter/rank/dedup picks one winner per language. Storage folder offset +1 in `download_recap`/`recap_exists`. YouTube search restricted to original language. Config sample + README + changelog updated.

**Tech Stack:** POSIX sh, curl, jq, yt-dlp, awk (POSIX). Branches: work happens on `feat/sonarr-recap-downloader`. Spec at `docs/superpowers/specs/2026-09-11-recaps-quality-design.md`, removed before PR.

---

### Task 1: Configurable search count + search logging

**Files:**
- Modify: `sonarr/connect/download_recap.sh:33-38` (defaults block), `:85-91` (`youtube_search`)

- [ ] **Step 1: Add RECAP_SEARCH_COUNT default**

In the defaults block, after `STORAGE_MODE`:

```sh
: "${RECAP_SEARCH_COUNT:=10}"
```

- [ ] **Step 2: Use it in youtube_search + add debug logs**

Replace `youtube_search` body (currently at lines 85-91):

```sh
youtube_search() {
    local _query _results _count

    _query="$1"
    _results=$(yt-dlp \
        --flat-playlist \
        -J \
        "ytsearch${RECAP_SEARCH_COUNT}:${_query}" 2>/dev/null | \
        jq -r '.entries[] | select(.id != null) | "\(.id)|\(.title | gsub("\\|"; "_"))"')
    _count=$(printf '%s\n' "${_results}" | grep -c '|' 2>/dev/null || echo 0)
    debug_log "YouTube search '${_query}': ${_count} results"
    printf '%s\n' "${_results}"
}
```

- [ ] **Step 3: Add debug count to get_tmdb_recaps**

Modify `get_tmdb_recaps` (lines 52-76): capture filtered output into a variable, log count, then print. Change the jq block to:

```sh
    _matches=$(printf '%s' "${_response}" | \
        jq -r '.results // empty | .[] | select(.type == "Recap" and .official == true and .site == "YouTube") | "\(.key)|\(.name | gsub("\\|"; "_"))|\(.iso_639_1 // empty)"')
    _count=$(printf '%s\n' "${_matches}" | grep -c '|' 2>/dev/null || echo 0)
    debug_log "TMDB season ${_season} videos (${_lang}): ${_count} recap matches"
    printf '%s\n' "${_matches}"
```

(Declare `_matches` with the other locals on line 53.)

- [ ] **Step 4: Commit**

```bash
git add sonarr/connect/download_recap.sh
git commit -m "feat(recap): configurable search count and debug logging"
```

---

### Task 2: Emit source tier on candidate lines

Candidate lines currently `source|yt_key|video_name|lang|is_original`; selection needs a 6th `tier` field (`tmdb|yt|fan`) for priority.

**Files:**
- Modify: `sonarr/connect/download_recap.sh:177-182` (TMDB emit), `:195-200` (YT official emit), `:220-225` (fanmade emit)

- [ ] **Step 1: Add tier to the three emitters in discover_recaps**

TMDB block (line 180):

```sh
                    printf 'official|%s|%s|%s|%s|tmdb\n' "${_yt_key}" "${_video_name}" "${_recap_lang:-${_lang}}" "${_is_original}"
```

YT official block (line 198):

```sh
                    printf 'official|%s|%s|%s|%s|yt\n' "${_yt_key}" "${_video_name}" "${_lang}" "${_is_original}"
```

Fanmade block (line 223):

```sh
                    printf 'fanmade|%s|%s|%s|%s|fan\n' "${_yt_key}" "${_video_name}" "${_lang}" "${_is_original}"
```

- [ ] **Step 2: Commit**

```bash
git add sonarr/connect/download_recap.sh
git commit -m "fix(recap): tag candidate sources with tier for ranking"
```

---

### Task 3: Restrict YouTube search to original language

**Files:**
- Modify: `sonarr/connect/download_recap.sh:188-203` (YT official loop), `:215-226` (fanmade loop)

- [ ] **Step 1: Original-lang-only loops**

Both Step 2 (official search) and Step 3 (fanmade) currently iterate `for _lang in ${_desired_langs}`. Replace the loop header in both with:

```sh
        for _lang in ${_series_lang}
        do
            _is_original="true"
```

and keep the per-lang body (`_query`, search, emit) unchanged. `_series_lang` is already resolved above (may be empty → loop body runs once with empty `_lang`; harmless, title filter applies).

- [ ] **Step 2: Commit**

```bash
git add sonarr/connect/download_recap.sh
git commit -m "fix(recap): restrict YouTube search to original language"
```

---

### Task 4: Select single best recap per language

Add `select_best_recaps()`: junk filter, recap-keyword rule for YT sources, per-key dedup (best tier), per-lang winner (best tier then best score).

**Files:**
- Modify: `sonarr/connect/download_recap.sh` — add function after `discover_recaps` (after line 227)

- [ ] **Step 1: Add the selection function**

```sh
# Select the single best recap candidate per language.
# Arguments: candidate_file recap_season
# Candidate file lines: source|yt_key|video_name|lang|is_original|tier
# Tier priority: tmdb (1) > yt (2) > fan (3); ties broken by title score.
# Outputs: "source|yt_key|video_name|lang|is_original" winner per lang.
select_best_recaps() {
    local _candidates _recap_season

    _candidates="$1"
    _recap_season="$2"

    [ ! -s "${_candidates}" ] && return 0

    debug_log "Selecting best recaps for season ${_recap_season}"

    awk -F'|' -v season="${_recap_season}" '
        function junk(t) {
            return (index(t, "trailer") || index(t, "teaser") ||
                    index(t, "soundtrack") || index(t, "reaction") ||
                    index(t, "review") || index(t, "interview") ||
                    index(t, "episode") || index(t, "crash course") ||
                    index(t, "live") || index(t, "official music"))
        }
        function score(t,   sc) {
            sc = 0
            if (t ~ ("(season[ .]?0*" season "|s0*" season "[^0-9]|[0-9]+-0*" season ")"))
                sc += 2
            if (index(t, "recap") > 0)
                sc += 1
            if (index(t, "before season") > 0)
                sc += 1
            return sc
        }
        {
            if ($2 == "") next
            key = $2; name = $3; lang = $4; orig = $5; tier = $6
            t = tolower(name)
            if (junk(t))
                next
            if (tier != "tmdb" && index(t, "recap") == 0)
                next
            prio = (tier == "tmdb" ? 1 : (tier == "yt" ? 2 : 3))
            sc = score(t)
            if ((key in kprio) && (prio > kprio[key] || \
                (prio == kprio[key] && sc < ksc[key])))
                next
            kprio[key] = prio; ksc[key] = sc; kline[key] = $1 "|" key "|" name "|" lang "|" orig
        }
        END {
            for (key in kline) {
                split(kline[key], f, "|")
                lang = f[4]
                prio = kprio[key]; sc = ksc[key]
                if ((lang in lprio) && (prio > lprio[lang] || \
                    (prio == lprio[lang] && sc < lsc[lang])))
                    continue
                lprio[lang] = prio; lsc[lang] = sc; lline[lang] = kline[key]
            }
            for (lang in lline)
                print lline[lang]
        }
    ' "${_candidates}" | while IFS='|' read -r _source _yt_key _video_name _lang _is_original; do
        debug_log "Selected '${_video_name}' (${_source}/${_lang}) for recap S${_recap_season}"
        printf '%s|%s|%s|%s|%s\n' "${_source}" "${_yt_key}" "${_video_name}" "${_lang}" "${_is_original}"
    done
}
```

Note: refer to the recap as `recap_season` (the debug string has a typo above — keep text `"Selecting best recaps for recap_season ${_recap_season}"`).

- [ ] **Step 2: Verify awk script against the observed failure data**

Run this standalone check (do not commit it — manual smoke test):

```sh
cat <<'EOF' | awk -F'|' -v season='5' '
  function junk(t) { return (index(t,"trailer") || index(t,"teaser") || index(t,"soundtrack") || index(t,"reaction") || index(t,"review") || index(t,"interview") || index(t,"episode") || index(t,"crash course") || index(t,"live") || index(t,"official music")) }
  function score(t,sc){ sc=0; if (t ~ ("(season[ .]?0*" season "|s0*" season "[^0-9]|[0-9]+-0*" season ")")) sc+=2; if (index(t,"recap")>0) sc+=1; if (index(t,"before season")>0) sc+=1; return sc }
  { if ($2=="") next; key=$2; name=$3; lang=$4; orig=$5; tier=$6; t=tolower(name); if (junk(t)) next; if (tier!="tmdb" && index(t,"recap")==0) next; prio=(tier=="tmdb"?1:(tier=="yt"?2:3)); sc=score(t); if ((key in kprio) && (prio>kprio[key] || (prio==kprio[key] && sc<ksc[key]))) next; kprio[key]=prio; ksc[key]=sc; kline[key]=$1"|"key"|"name"|"lang"|"orig }
  END { for (key in kline) { split(kline[key],f,"|"); lang=f[4]; prio=kprio[key]; sc=ksc[key]; if ((lang in lprio) && (prio>lprio[lang] || (prio==lprio[lang] && sc<lsc[lang]))) continue; lprio[lang]=prio; lsc[lang]=sc; lline[lang]=kline[key] } for (lang in lline) print lline[lang] }
'
official|0ACXopjl1fA|The Handmaid's Tale Season 5 Recap _ Must Watch Before Final Season 6|en|true|yt
official|rtjYdkQmmjk|The Handmaid's Tale Season 5 in 3 Minutes or Less|en|true|yt
official|4yxOdf48IVw|The Handmaids Tale Season 5 Recap|en|true|yt
fanmade|wHtZqojunC8|THE HANDMAID'S TALE Season 1-5 Recap _ Must Watch Before Season 6 _ Series Explained|en|true|fan
official|PZYsS5uB2Kc|Handmaid's Tale Season 5 Recap _ MUST WATCH BEFORE SEASON 6|en|true|yt
official|Z7LmO83lWIs|THE HANDMAID'S TALE _ TRAILER 4 TEMPORADA - LEGENDADO|pt-BR|false|yt
official|B8mJoG3UeRg|Five Minutes, Then I'll Go _ The Handmaid's Tale S04 Original Soundtrack|pt-BR|false|tmdb
EOF
```

Expected: exactly 1 line (the en winner). pt-BR has no non-junk candidate (`soundtrack` is junk) so no pt-BR line appears. The en winner must be a valid recap of season 5.

- [ ] **Step 3: Commit**

```bash
git add sonarr/connect/download_recap.sh
git commit -m "feat(recap): rank candidates and download single best per language"
```

---

### Task 5: Wire selection into event and backfill paths

Both `process_event` and `process_series_backfill` currently loop every candidate line. Replace with: run `.recaps_temp` through `select_best_recaps`, write winners to a second temp, loop over that. (The pipe-into-subshell changes `_has_new`, so redirect into a temp file instead.)

**Files:**
- Modify: `sonarr/connect/download_recap.sh:379-412` (`process_event`), `:433-472` (`process_series_backfill`)

- [ ] **Step 1: process_event — select before download loop**

Replace the download-loop block (lines 394-408). Note the second temp + traps:

```sh
    _has_new=false
    _selected_temp=$(mktemp)
    # shellcheck disable=SC2064
    trap 'rm -f "${_recaps_temp}" "${_selected_temp}"; exit 130' INT TERM
    trap 'rm -f "${_recaps_temp}" "${_selected_temp}"' EXIT

    select_best_recaps "${_recaps_temp}" "${_recap_season}" > "${_selected_temp}"

    if [ -s "${_selected_temp}" ]
    then
        while IFS='|' read -r _source _yt_key _video_name _lang _is_original; do
            if [ -n "${_yt_key}" ]
            then
                download_recap "${_yt_key}" "${_video_name}" "${_source}" "${_lang}" "${_is_original}" "${_recap_season}" "${_series_path}"
                _dl_status=$?
                case $_dl_status in
                    0) _has_new=true ;;
                    1) debug_log "Skipped, already downloaded" ;;
                    2) debug_log "Dry-run, would download" ;;
                    *) echo "ERROR: Failed to download recap ${_yt_key} for series ${SERIES_ID}" >&2 ;;
                esac
            fi
        done < "${_selected_temp}"
    else
        debug_log "No qualifying recaps for season ${_recap_season}"
    fi

    [ "${_has_new}" = "true" ] && [ "${DRY_RUN}" != "true" ] && notify_autopulse "${_series_path}"
    rm -f "${_recaps_temp}" "${_selected_temp}"
    trap - INT TERM EXIT
```

- [ ] **Step 2: process_series_backfill — same pattern**

Replace lines 447-465 (the per-season discover+download) with:

```sh
        discover_recaps "${_series_title}" "${_tmdb_id}" "${_recap_season}" "${_recaps_temp}"

        if [ ! -s "${_recaps_temp}" ]
        then
            debug_log "No recaps found for ${_series_title} season ${_recap_season}"
        else
            _selected_temp=$(mktemp)
            select_best_recaps "${_recaps_temp}" "${_recap_season}" > "${_selected_temp}"
            if [ -s "${_selected_temp}" ]
            then
                while IFS='|' read -r _source _yt_key _video_name _lang _is_original; do
                    if [ -n "${_yt_key}" ]
                    then
                        download_recap "${_yt_key}" "${_video_name}" "${_source}" "${_lang}" "${_is_original}" "${_recap_season}" "${_series_path}"
                        _dl_status=$?
                        case $_dl_status in
                            0) _has_new=true ;;
                            1) debug_log "Skipped, already downloaded" ;;
                            2) debug_log "Dry-run, would download" ;;
                            *) echo "ERROR: Failed to download recap ${_yt_key} for series ${_series_id}" >&2 ;;
                        esac
                    fi
                done < "${_selected_temp}"
            fi
            rm -f "${_selected_temp}"
        fi

        sleep 1
```

Update the function header comment "Each line: source|youtube_key|video_name|lang|is_original" to mention tier.

- [ ] **Step 3: Commit**

```bash
git add sonarr/connect/download_recap.sh
git commit -m "feat(recap): route downloads through best-candidate selection"
```

---

### Task 6: Store recap of N in Season N+1 folder

**Files:**
- Modify: `sonarr/connect/download_recap.sh:106-122` (`recap_exists`), `:229-257` (`download_recap` storage)

- [ ] **Step 1: recap_exists — check watched season folder**

Replace lines 106-122 so the season-folder check uses `_recap_season + 1`:

```sh
recap_exists() {
    local _series_path _recap_season _season_label _watched_season _watched_label

    _series_path="$1"
    _recap_season="$2"
    _season_label=$(printf '%02d' "${_recap_season}")
    _watched_season=$((_recap_season + 1))
    _watched_label=$(printf '%02d' "${_watched_season}")

    if ls "${_series_path}/Other/Recap-S${_season_label}-"*.mp4 >/dev/null 2>&1
    then
        return 0
    fi
    if ls "${_series_path}/Season ${_watched_label}/Other/Recap-S${_season_label}-"*.mp4 >/dev/null 2>&1
    then
        return 0
    fi
    return 1
}
```

- [ ] **Step 2: download_recap — watched season folder**

Replace the storage vars (lines 243-246):

```sh
    _season_label=$(printf '%02d' "${_recap_season}")
    _watched_season=$((_recap_season + 1))
    _watched_label=$(printf '%02d' "${_watched_season}")
    _filename="Recap-S${_season_label}-${_source}-${_lang}.mp4"
    _show_dir="${_series_path}/Other"
    _season_dir="${_series_path}/Season ${_watched_label}/Other"
```

Everything downstream (target resolution, hardlink `_season_dir`) stays the same.

- [ ] **Step 3: Commit**

```bash
git add sonarr/connect/download_recap.sh
git commit -m "fix(recap): store recap of season N in the Season N+1 folder"
```

---

### Task 7: Debug transparency for backfill

**Files:**
- Modify: `sonarr/connect/download_recap.sh:430-431` (seasons query), `:438-445` (per-season loop)

- [ ] **Step 1: Log Sonarr seasons response and per-season intent**

After `_seasons` is computed (line 431), add:

```sh
    debug_log "Series ${_series_id} (${_series_title}): downloaded seasons >= 2: $(printf '%s' "${_seasons}" | tr '\n' ' ')"
```

Inside the loop, before the existing `recap_exists` check:

```sh
        debug_log "Season ${_season} downloaded, want recap of season ${_recap_season} (stored in Season ${_recap_season} + 1 folder)"
```

- [ ] **Step 2: Commit**

```bash
git add sonarr/connect/download_recap.sh
git commit -m "feat(recap): log sonarr seasons response and recap intent in backfill"
```

---

### Task 8: Config sample, README, changelog

**Files:**
- Modify: `sonarr/scripts.conf.sample:17-21` (FAN_MADE wording), add RECAP_SEARCH_COUNT
- Modify: `README.md:374-403` (recap section)
- Modify: `sonarr/connect/download_recap.sh:20-26` (changelog)

- [ ] **Step 1: Config sample**

Add after `STORAGE_MODE`:

```sh
# How many YouTube results to consider per recap search (default 10)
RECAP_SEARCH_COUNT="10"
```

Update the `FAN_MADE=always` comment: `always   - always also search fan-made; official recaps still rank higher`.

Update `STORAGE_MODE` comments to reflect new placement (`season` example becomes `Series/Season 02/Other/Recap-S01-official-en.mp4` — recap of S01 lives in S02).

- [ ] **Step 2: README**

Update the recap section (lines 379-389) to state: one best recap per language; recap of season N stored in Season N+1 folder (filename names recapped season); YouTube searched in original language only; junk titles filtered. Add a cleanup one-liner after the backfill paragraph:

```sh
# Remove pre-v0.2.0 misnamed/junk recap files
find /path/to/Series -path "*/Other/Recap-*" -type f -delete
```

- [ ] **Step 3: Changelog header**

Add above the 0.1.0 block:

```sh
# Version 0.2.0 (Released 2026-09-11)
#   * Download single best recap per (season, language) via candidate ranking
#   * Store recap of season N in the Season N+1 folder
#   * Restrict YouTube recap search to the series original language
#   * Filter junk titles (trailers, reactions, soundtracks, episode recaps)
#   * Configurable search width via RECAP_SEARCH_COUNT
#   * Richer debug output (queries, counts, selection rationale)
```

- [ ] **Step 4: Commit**

```bash
git add sonarr/scripts.conf.sample README.md sonarr/connect/download_recap.sh
git commit -m "docs(recap): document v0.2.0 selection, storage, and search behavior"
```

---

### Task 9: Verification, spec/plan cleanup, push

**Files:**
- Modify: remove `docs/superpowers/specs/2026-09-11-recaps-quality-design.md` and `docs/superpowers/plans/2026-09-11-recaps-quality.md`
- Verify: `sonarr/connect/download_recap.sh`

- [ ] **Step 1: shellcheck + syntax**

```bash
shellcheck -e SC1091,SC3043 sonarr/connect/download_recap.sh
sh -n sonarr/connect/download_recap.sh
```

Both must pass clean.

- [ ] **Step 2: Dry-run smoke test** (on a machine with Sonarr + TMDB access, or with the test sonarr fixture if available)

```bash
./sonarr/connect/download_recap.sh -n -d Bulk
```

Expected: for each series, selected-lines debug, winners only, no download to same filename twice, stored paths in the `Season N+1/Other` shape.

- [ ] **Step 3: Remove spec and plan docs (repository does not keep them), commit, push**

```bash
git rm docs/superpowers/specs/2026-09-11-recaps-quality-design.md docs/superpowers/plans/2026-09-11-recaps-quality.md
git add -u
git commit -m "chore(recap): drop development spec and plan docs"
git push -u origin feat/sonarr-recap-downloader
```

- [ ] **Step 4: Confirm PR #7 description reflects v0.2.0 behavior**; leave PR open for review.