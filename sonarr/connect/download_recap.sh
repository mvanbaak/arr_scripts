#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Script to download previous season recap videos when a new season of a TV
# series starts in Sonarr.
# Official recaps come from TMDB (season videos endpoint) and YouTube.
# Fan-made recap search is optional (FAN_MADE config).
# Recaps are stored following the Plex naming scheme for TV show extras.
#
# Requirements:
# * curl
# * jq
# * ln
# * mkdir
# * mktemp
# * tr
# * yt-dlp
#
# Version 0.1.0 (Released 2026-09-11)
#   * Initial implementation
#     * TMDB official recap discovery (season videos endpoint)
#     * YouTube official + fan-made recap search via yt-dlp
#     * Plex-compatible storage: show level, season level, or both (hardlink)
#     * Multi-language recaps with subtitles for original-language content
#     * Sonarr Connect Download trigger plus bulk backfill mode

# Load shared library and configuration
. "$(dirname "$0")/../../common/scripts_common.sh"
load_config "$(dirname "$0")/.."

# Recap-specific defaults
: "${RECAP_LANGUAGES:=original,pt-BR}"
: "${RECAP_SUBTITLE_LANGS:=pt-BR}"
: "${FAN_MADE:=fallback}"
: "${STORAGE_MODE:=show}"
: "${RECAP_SEARCH_COUNT:=10}"
: "${DRY_RUN:=false}"
: "${DEBUG:=false}"

# Information set on the environment by sonarr
# Can be overridden by command line arguments:
# $0 <event_type> <series_id> [season_number]
# Use defaults to mimic a Test event from sonarr
EVENT_TYPE="${sonarr_eventtype:-"Test"}"
SERIES_ID="${sonarr_series_id:-0}"
SEASON_NUMBER="${sonarr_episodefile_seasonnumber:-0}"
EPISODE_NUMBERS="${sonarr_episodefile_episodenumbers:-""}"

# Query TMDB for official recap videos for a season
# Arguments: tmdb_id season_number language
# Outputs: lines of "youtube_key|video_name|iso_639_1" for each matching recap
get_tmdb_recaps() {
    local _tmdb_id _season _lang _response _matches _count

    _tmdb_id="$1"
    _season="$2"
    _lang="$3"

    if [ -z "${TMDB_API_KEY}" ]
    then
        echo "ERROR: TMDB_API_KEY is not set" >&2
        return 1
    fi

    _response=$(curl -s \
        "https://api.themoviedb.org/3/tv/${_tmdb_id}/season/${_season}/videos?api_key=${TMDB_API_KEY}&language=${_lang}")

    if [ -z "${_response}" ]
    then
        echo "ERROR: No response from TMDB for series ${_tmdb_id} season ${_season}, language ${_lang}" >&2
        return 1
    fi

    _matches=$(printf '%s' "${_response}" | \
        jq -r '.results // empty | .[] | select(.type == "Recap" and .official == true and .site == "YouTube") | "\(.key)|\(.name | gsub("\\|"; "_"))|\(.iso_639_1 // empty)"')
    _count=$(printf '%s\n' "${_matches}" | grep -c '|' 2>/dev/null || true)
    debug_log "TMDB season ${_season} videos (${_lang}): ${_count} recap matches"
    printf '%s\n' "${_matches}"
}

# Search YouTube for recap videos using yt-dlp
# Arguments: search_query
# Outputs: lines of "youtube_key|video_title"
youtube_search() {
    local _query _results _count

    _query="$1"
    _results=$(yt-dlp \
        --flat-playlist \
        -J \
        "ytsearch${RECAP_SEARCH_COUNT}:${_query}" 2>/dev/null | \
        jq -r '.entries[] | select(.id != null) | "\(.id)|\(.title | gsub("\\|"; "_"))"')
    _count=$(printf '%s\n' "${_results}" | grep -c '|' 2>/dev/null || true)
    debug_log "YouTube search '${_query}': ${_count} results"
    printf '%s\n' "${_results}"
}

# Compare a comma-separated episode number list against the season premiere
# Arguments: episode_numbers_csv
# Returns 0 if episode 1 is in the list, 1 otherwise
season_has_premiere() {
    case ",$1," in
        *,1,*) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if a recap for a season already exists in either storage location
# Arguments: series_path recap_season
# Returns 0 if present, 1 if missing
recap_exists() {
    local _series_path _recap_season _season_label

    _series_path="$1"
    _recap_season="$2"
    _season_label=$(printf '%02d' "${_recap_season}")

    if ls "${_series_path}/Other/Recap-S${_season_label}-"*.mp4 >/dev/null 2>&1
    then
        return 0
    fi
    if ls "${_series_path}/Season ${_season_label}/Other/Recap-S${_season_label}-"*.mp4 >/dev/null 2>&1
    then
        return 0
    fi
    return 1
}

# Discover recap videos for a season and write them to a file.
# Each line: "source|youtube_key|video_name|lang|is_original|tier"
# Arguments: series_title tmdb_id recap_season output_file
discover_recaps() {
    local _series_title _tmdb_id _recap_season _output_file
    local _series_lang _desired_langs _lang _is_original
    local _official_found _query _yt_key _video_name _recap_lang

    _series_title="$1"
    _tmdb_id="$2"
    _recap_season="$3"
    _output_file="$4"

    : > "${_output_file}"
    _official_found=false

    # Resolve original language from TMDB series details
    _series_lang=""
    if [ -n "${_tmdb_id}" ]
    then
        _series_lang=$(curl -s \
            "https://api.themoviedb.org/3/tv/${_tmdb_id}?api_key=${TMDB_API_KEY}" | \
            jq -r '.original_language // empty')
    fi

    # Build list of desired languages, resolving "original" to the series language
    # RECAP_LANGUAGES is comma-separated, e.g. "original,pt-BR"
    _desired_langs=""
    # shellcheck disable=SC2086
    for _lang in $(printf '%s' "${RECAP_LANGUAGES}" | tr ',' ' ')
    do
        if [ "${_lang}" = "original" ]
        then
            if [ -n "${_series_lang}" ]
            then
                _desired_langs="${_desired_langs} ${_series_lang}"
            fi
        else
            _desired_langs="${_desired_langs} ${_lang}"
        fi
    done

    if [ -z "${_desired_langs}" ]
    then
        debug_log "No desired languages for series ${_series_title}"
        return 0
    fi

    # Step 1: official recaps from TMDB season videos
    for _lang in ${_desired_langs}
    do
        _is_original="false"
        [ "${_lang}" = "${_series_lang}" ] && _is_original="true"
        get_tmdb_recaps "${_tmdb_id}" "${_recap_season}" "${_lang}" | while IFS='|' read -r _yt_key _video_name _recap_lang _; do
            if [ -n "${_yt_key}" ]
            then
                printf 'official|%s|%s|%s|%s|tmdb\n' "${_yt_key}" "${_video_name}" "${_recap_lang:-${_lang}}" "${_is_original}"
            fi
        done >> "${_output_file}"
    done

    [ -s "${_output_file}" ] && _official_found=true

    # Step 2: YouTube official recap search if TMDB found nothing
    if [ "${_official_found}" = "false" ]
    then
        for _lang in ${_series_lang}
        do
            _is_original="true"
            _query="${_series_title} season ${_recap_season} recap official ${_lang}"
            youtube_search "${_query}" | while IFS='|' read -r _yt_key _video_name; do
                if [ -n "${_yt_key}" ]
                then
                    printf 'official|%s|%s|%s|%s|yt\n' "${_yt_key}" "${_video_name}" "${_lang}" "${_is_original}"
                fi
            done >> "${_output_file}"
        done
        [ -s "${_output_file}" ] && _official_found=true
    fi

    # Step 3: fan-made recap search, per FAN_MADE config
    case "${FAN_MADE}" in
        never) return 0 ;;
        always) ;;
        *)
            # fallback: only search fan-made when no official recap was found
            [ "${_official_found}" = "true" ] && return 0
            ;;
    esac

    for _lang in ${_series_lang}
    do
        _is_original="true"
        _query="${_series_title} season ${_recap_season} recap ${_lang}"
        youtube_search "${_query}" | while IFS='|' read -r _yt_key _video_name; do
            if [ -n "${_yt_key}" ]
            then
                printf 'fanmade|%s|%s|%s|%s|fan\n' "${_yt_key}" "${_video_name}" "${_lang}" "${_is_original}"
            fi
        done >> "${_output_file}"
    done
}

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

# Download a single recap video and place it per STORAGE_MODE
# Arguments: yt_key video_name source lang is_original recap_season series_path
download_recap() {
    local _yt_key _video_name _source _lang _is_original _recap_season _series_path
    local _season_label _filename _show_dir _season_dir _target _subtitle_flags _cookie_flags

    _yt_key="$1"
    _video_name="$2"
    _source="$3"
    _lang="$4"
    _is_original="$5"
    _recap_season="$6"
    _series_path="$7"

    _season_label=$(printf '%02d' "${_recap_season}")
    _filename="Recap-S${_season_label}-${_source}-${_lang}.mp4"
    _show_dir="${_series_path}/Other"
    _season_dir="${_series_path}/Season ${_season_label}/Other"

    case "${STORAGE_MODE}" in
        season)
            _target="${_season_dir}/${_filename}"
            ;;
        *)
            _target="${_show_dir}/${_filename}"
            ;;
    esac

    if [ -f "${_target}" ]
    then
        debug_log "Recap already downloaded, skipping: ${_filename}"
        return 1
    fi

    # Build subtitle flags - only for original-language recaps
    _subtitle_flags=""
    if [ "${_is_original}" = "true" ] && [ -n "${RECAP_SUBTITLE_LANGS}" ]
    then
        _subtitle_flags="--write-subs --sub-langs ${RECAP_SUBTITLE_LANGS}"
    fi

    # Build cookie flags - only if cookie file is set and exists
    _cookie_flags=""
    if [ -n "${YT_DLP_COOKIE_FILE}" ]
    then
        if [ -f "${YT_DLP_COOKIE_FILE}" ]
        then
            _cookie_flags="--cookies ${YT_DLP_COOKIE_FILE}"
        else
            echo "WARN: YT_DLP_COOKIE_FILE is set but file not found: ${YT_DLP_COOKIE_FILE}" >&2
        fi
    fi

    if [ "${DRY_RUN}" = "true" ]
    then
        echo "DRY-RUN: Download '${_video_name}' (${_source}/${_lang}) → ${_target}" >&2
        echo "DRY-RUN: yt-dlp -o \"${_target}\" -f \"${YT_DLP_FORMAT}\" --recode-video \"${YT_DLP_RECODE}\" ${_subtitle_flags} ${_cookie_flags} \"https://www.youtube.com/watch?v=${_yt_key}\"" >&2
        return 2
    fi

    # Create directories if needed
    mkdir -p "$(dirname "${_target}")"
    if [ "${STORAGE_MODE}" = "both" ]
    then
        mkdir -p "${_season_dir}"
    fi

    debug_log "Downloading recap '${_video_name}' (${_source}/${_lang}) for ${_series_path}"

    # shellcheck disable=SC2086
    yt-dlp \
        -o "${_target}" \
        -f "${YT_DLP_FORMAT}" \
        --recode-video "${YT_DLP_RECODE}" \
        ${_subtitle_flags} \
        ${_cookie_flags} \
        "https://www.youtube.com/watch?v=${_yt_key}"

    # In both mode the download lands at show level; hardlink into the season folder.
    # Hardlink fails across filesystems, so fall back to a copy.
    if [ "${STORAGE_MODE}" = "both" ] && [ -f "${_target}" ]
    then
        if ! ln "${_target}" "${_season_dir}/${_filename}"
        then
            echo "WARN: Hardlink failed for ${_filename}, copying instead" >&2
            cp "${_target}" "${_season_dir}/${_filename}"
        fi
    fi
}

# Process a single Sonarr Download event for a newly-started season
process_event() {
    local _series_info _series_path _series_title _tmdb_id
    local _recap_season _recaps_temp _has_new _dl_status
    local _source _yt_key _video_name _lang

    case "${SEASON_NUMBER}" in
        ''|*[!0-9]*)
            echo "ERROR: Invalid season number: ${SEASON_NUMBER}" >&2
            return 1
            ;;
        0|1)
            debug_log "Season ${SEASON_NUMBER} has no previous season to recap, skipping"
            return 0
            ;;
    esac

    # Episode numbers are set on real Sonarr events: only act on the season premiere
    if [ -n "${EPISODE_NUMBERS}" ]
    then
        if ! season_has_premiere "${EPISODE_NUMBERS}"
        then
            debug_log "Downloaded episodes (${EPISODE_NUMBERS}) do not include the premiere, skipping recap"
            return 0
        fi
    fi

    _recap_season=$((SEASON_NUMBER - 1))
    debug_log "Season ${SEASON_NUMBER} started, looking for season ${_recap_season} recap"

    # Fetch series info from Sonarr
    if ! _series_info=$(get_series_info "${SERIES_ID}")
    then
        echo "ERROR: Failed to get series info for id ${SERIES_ID}" >&2
        return 1
    fi

    _series_title=$(printf '%s' "${_series_info}" | jq -r '.title // empty')
    _series_path=$(printf '%s' "${_series_info}" | jq -r '.path // empty')
    _tmdb_id=$(printf '%s' "${_series_info}" | jq -r '.tmdbId // empty')

    if [ -z "${_series_path}" ]
    then
        echo "ERROR: Series ${SERIES_ID} has no path in Sonarr" >&2
        return 1
    fi

    if [ -z "${_tmdb_id}" ]
    then
        echo "WARN: Series ${SERIES_ID} has no tmdbId, cannot query TMDB for official recap" >&2
    fi

    # Skip if a recap already exists
    if recap_exists "${_series_path}" "${_recap_season}"
    then
        debug_log "Recap for season ${_recap_season} already exists, skipping"
        return 0
    fi

    # Discover recap candidates into a temp file
    _recaps_temp=$(mktemp)
    # shellcheck disable=SC2064
    trap 'rm -f "${_recaps_temp}"; exit 130' INT TERM
    trap 'rm -f "${_recaps_temp}"' EXIT

    discover_recaps "${_series_title}" "${_tmdb_id}" "${_recap_season}" "${_recaps_temp}"

    if [ ! -s "${_recaps_temp}" ]
    then
        debug_log "No recaps found for ${_series_title} season ${_recap_season}"
        rm -f "${_recaps_temp}"
        trap - INT TERM EXIT
        return 0
    fi

    # Download each recap, track if anything is actually new
    _has_new=false
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
    done < "${_recaps_temp}"

    [ "${_has_new}" = "true" ] && [ "${DRY_RUN}" != "true" ] && notify_autopulse "${_series_path}"
    rm -f "${_recaps_temp}"
    trap - INT TERM EXIT
}

# Backfill recaps for a single series: find downloaded seasons >= 2 that lack a recap
# Arguments: series_id series_title series_path tmdb_id
process_series_backfill() {
    local _series_id _series_title _series_path _tmdb_id
    local _seasons _season _recap_season _recaps_temp _has_new _dl_status
    local _source _yt_key _video_name _lang _is_original

    _series_id="$1"
    _series_title="$2"
    _series_path="$3"
    _tmdb_id="$4"
    _has_new=false

    [ -z "${_series_path}" ] && return 0

    _seasons=$(sonarr_api_get "episode?seriesId=${_series_id}" | \
        jq -r '[.[] | select(.hasFile == true and .seasonNumber >= 2)] | map(.seasonNumber) | unique[]')

    _recaps_temp=$(mktemp)
    # shellcheck disable=SC2064
    trap 'rm -f "${_recaps_temp}"; exit 130' INT TERM
    trap 'rm -f "${_recaps_temp}"' EXIT

    for _season in ${_seasons}
    do
        _recap_season=$((_season - 1))
        if recap_exists "${_series_path}" "${_recap_season}"
        then
            debug_log "Recap for season ${_recap_season} already exists, skipping"
            continue
        fi

        discover_recaps "${_series_title}" "${_tmdb_id}" "${_recap_season}" "${_recaps_temp}"

        if [ ! -s "${_recaps_temp}" ]
        then
            debug_log "No recaps found for ${_series_title} season ${_recap_season}"
        else
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
            done < "${_recaps_temp}"
        fi

        sleep 1
    done

    rm -f "${_recaps_temp}"
    trap - INT TERM EXIT

    [ "${_has_new}" = "true" ] && [ "${DRY_RUN}" != "true" ] && notify_autopulse "${_series_path}"
}

# Process all series in Sonarr (bulk/backfill mode)
process_all_series() {
    local _series_list _counter _series_id _series_title _series_path _tmdb_id

    _counter=0
    _series_list=$(sonarr_api_get "series" | \
        jq -r 'sort_by(.id)[] | "\(.id)|\(.title)|\(.path)|\(.tmdbId // empty)"')

    while IFS='|' read -r _series_id _series_title _series_path _tmdb_id; do
        if [ -z "${_series_id}" ]
        then
            continue
        fi
        _counter=$((_counter+1))
        debug_log "(${_counter}) Processing series '${_series_title}' with path '${_series_path}'"
        process_series_backfill "${_series_id}" "${_series_title}" "${_series_path}" "${_tmdb_id}"
        sleep 1
    done <<EOF
${_series_list}
EOF
}

# main script flow
check_needed_executables "curl jq ln mkdir mktemp tr yt-dlp"

if [ -z "${TMDB_API_KEY}" ]
then
    echo "ERROR: TMDB_API_KEY is not set. Configure it in common/scripts.conf" >&2
    exit 1
fi

case "${FAN_MADE}" in
    never|fallback|always) ;;
    *)
        echo "ERROR: Invalid FAN_MADE value: ${FAN_MADE}. Must be never, fallback, or always." >&2
        exit 1
        ;;
esac

case "${STORAGE_MODE}" in
    show|season|both) ;;
    *)
        echo "ERROR: Invalid STORAGE_MODE value: ${STORAGE_MODE}. Must be show, season, or both." >&2
        exit 1
        ;;
esac

# Parse optional flags before positional args
while [ $# -gt 0 ]; do
    case "$1" in
        -n) DRY_RUN=true; shift ;;
        -d) DEBUG=true; shift ;;
        -h|--help)
            echo "Usage: $0 [-n] [-d] [event_type] [series_id] [season_number]"
            echo ""
            echo "Download previous season recap videos for TV series in Sonarr."
            echo ""
            echo "Options:"
            echo "  -n    Dry-run mode"
            echo "  -d    Debug logging"
            echo "  -h    Show this help"
            echo ""
            echo "Event types: Test, Download, Bulk"
            exit 0
            ;;
        *) break ;;
    esac
done

if [ -n "$1" ]
then
    EVENT_TYPE="$1"
fi

if [ -n "$2" ]
then
    SERIES_ID="$2"
fi

if [ -n "$3" ]
then
    SEASON_NUMBER="$3"
fi

case "${EVENT_TYPE}" in
    Test)
        debug_log "Received test event, signal success"
        exit 0
        ;;
    Download)
        debug_log "Got event ${EVENT_TYPE}, handling"
        process_event
        ;;
    [Bb]ulk)
        # This event does not exist in sonarr, but can be triggered
        # by a cli invokation of this script. eg
        # ./download_recap.sh bulk
        : "${DRY_RUN:=true}"
        : "${DEBUG:=true}"
        debug_log "Got event ${EVENT_TYPE}, handling"
        process_all_series
        ;;
    *)
        echo "ERROR: Got event ${EVENT_TYPE} that cannot be handled, exiting" >&2
        exit 4
        ;;
esac
