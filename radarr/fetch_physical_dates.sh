#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Script to search Blu-ray.com for physical release dates missing from Radarr.
# Logs results for manual TMDB submission.
#
# Requirements:
# * sh (tested with sh from FreeBSD base FreeBSD 14.1)
# * curl (tested with 8.10.1)
# * jq (tested with 1.7.1)
#
# Version 0.1.0 (Released 2026-07-27)
#   * Initial implementation

# Load shared library and configuration
. "$(dirname "$0")/connect/scripts_common.sh"
load_config "$(dirname "$0")/connect"

# Script-specific defaults
: "${BLURAY_COUNTRY:=US}"
: "${BLURAY_RATE_LIMIT:=0.5}"
: "${BLURAY_MAX_MOVIES_WARN:=50}"
: "${DEBUG:=false}"

# CLI flags
_FLAG_JSON=false
_FLAG_QUIET=false
_FLAG_CSV=false
_LIMIT=0
_EXPORT_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --json) _FLAG_JSON=true; shift ;;
        --quiet) _FLAG_QUIET=true; shift ;;
        --csv) _FLAG_CSV=true; shift ;;
        --limit)
            case "$2" in
                ''|*[!0-9]*)
                    echo "ERROR: --limit requires a positive integer" >&2
                    exit 1
                    ;;
                *) _LIMIT="$2"; shift 2 ;;
            esac
            ;;
        --export)
            case "$2" in
                '') echo "ERROR: --export requires a file path" >&2; exit 1 ;;
                *) _EXPORT_FILE="$2"; shift 2 ;;
            esac
            ;;
        --country)
            case "$2" in
                '') echo "ERROR: --country requires a code (e.g. US, UK)" >&2; exit 1 ;;
                *) BLURAY_COUNTRY="$2"; shift 2 ;;
            esac
            ;;
        --debug) DEBUG=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Search Blu-ray.com for physical release dates missing from Radarr."
            echo ""
            echo "Options:"
            echo "  --limit N          Process max N movies per run"
            echo "  --export <file>    Write results to file (JSON or CSV)"
            echo "  --csv              Export as CSV (default: JSON)"
            echo "  --json             JSON output to stdout"
            echo "  --quiet            Suppress table output"
            echo "  --country <code>   Country filter (default: US)"
            echo "  --debug            Verbose logging"
            echo "  -h, --help         Show this help"
            exit 0
            ;;
        -*) echo "ERROR: Unknown flag: $1" >&2; exit 1 ;;
        *) break ;;
    esac
done

check_needed_executables "curl jq"

debug_log "=== Fetch Physical Release Dates ==="
debug_log "Country filter: ${BLURAY_COUNTRY}"
debug_log "Rate limit: ${BLURAY_RATE_LIMIT}s"

# --json takes precedence over --quiet
if [ "${_FLAG_JSON}" = "true" ]
then
    _FLAG_QUIET=false
fi

##############################################################################
# Blu-ray.com lookup
##############################################################################

bluray_lookup() {
    local _title _year _response _items _matched

    _title="$1"
    _year="$2"

    _response=$(curl -sL \
        -H "User-Agent: Mozilla/5.0" \
        "https://m.blu-ray.com/quicksearch/search.php?section=bluraymovies&country=ALL&keyword=$(printf '%s' "${_title}" | jq -sRr @uri)&_=$(date +%s)000")

    if [ -z "${_response}" ]
    then
        debug_log "  No response from Blu-ray.com for '${_title}'"
        return 1
    fi

    _items=$(printf '%s' "${_response}" | jq -e '.items // empty' 2>/dev/null)
    if [ -z "${_items}" ] || [ "${_items}" = "[]" ]
    then
        debug_log "  No results on Blu-ray.com for '${_title}'"
        return 1
    fi

    # Filter: matching country flag, matching year, has release date
    _matched=$(printf '%s' "${_items}" | jq -r --arg flag "flags/${BLURAY_COUNTRY}.png" --arg year "${_year}" '
        [.[] |
            select(
                (.flag | endswith($flag))
                and ((.year | tostring) == $year)
                and (.reldate != null)
                and (.reldate != "No release date")
            )
        ] | sort_by(.reldate) | .[0] // empty
    ')

    if [ -z "${_matched}" ] || [ "${_matched}" = "null" ] || [ "${_matched}" = "" ]
    then
        debug_log "  No ${BLURAY_COUNTRY} release found for '${_title} (${_year})'"
        return 1
    fi

    printf '%s' "${_matched}"
}

##############################################################################
# Phase 1: Radarr query
##############################################################################

debug_log "Fetching all movies from Radarr API"
_ALL_MOVIES=$(radarr_api_get "movie")

if [ -z "${_ALL_MOVIES}" ]
then
    echo "ERROR: No response from movie API" >&2
    exit 1
fi

_CANDIDATES=$(printf '%s' "${_ALL_MOVIES}" | jq '
[.[] | select(
    (.physicalRelease == null or .physicalRelease == "")
    and (.tmdbId != null and .tmdbId != 0)
) | {id: .id, title: .title, year: .year, tmdbId: .tmdbId}]
')

# Unset to free memory
unset _ALL_MOVIES

_CANDIDATE_COUNT=$(printf '%s' "${_CANDIDATES}" | jq 'length')

debug_log "Candidates: ${_CANDIDATE_COUNT} movies without physical release"

if [ "${_CANDIDATE_COUNT}" -eq 0 ]
then
    if [ "${_FLAG_QUIET}" = "false" ]
    then
        echo "No movies found without physical release dates."
    fi
    exit 0
fi

if [ "${_CANDIDATE_COUNT}" -gt "${BLURAY_MAX_MOVIES_WARN}" ] && [ "${_LIMIT}" -eq 0 ]
then
    echo "WARN: ${_CANDIDATE_COUNT} movies to check. Consider --limit N to batch." >&2
fi

# Apply limit
if [ "${_LIMIT}" -gt 0 ] && [ "${_LIMIT}" -lt "${_CANDIDATE_COUNT}" ]
then
    _CANDIDATES=$(printf '%s' "${_CANDIDATES}" | jq --argjson limit "${_LIMIT}" '.[:$limit]')
    _CANDIDATE_COUNT="${_LIMIT}"
    debug_log "Limited to ${_LIMIT} movies"
fi

##############################################################################
# Phase 2: Blu-ray.com lookups
##############################################################################

_RESULTS="[]"
_FOUND_COUNT=0
_CHECKED_COUNT=0

_TEMP=$(mktemp)
# shellcheck disable=SC2064
trap 'rm -f "${_TEMP}"; exit 130' INT TERM
trap 'rm -f "${_TEMP}"' EXIT

printf '%s' "${_CANDIDATES}" | jq -c '.[]' > "${_TEMP}"

while read -r _movie
do
    _CHECKED_COUNT=$((_CHECKED_COUNT + 1))
    _title=$(printf '%s' "${_movie}" | jq -r '.title')
    _year=$(printf '%s' "${_movie}" | jq -r '.year')
    _radarr_id=$(printf '%s' "${_movie}" | jq -r '.id')
    _tmdb_id=$(printf '%s' "${_movie}" | jq -r '.tmdbId')

    debug_log "[${_CHECKED_COUNT}/${_CANDIDATE_COUNT}] Looking up: ${_title} (${_year})"

    _result=$(bluray_lookup "${_title}" "${_year}")
    _lookup_rc=$?

    if [ "${_lookup_rc}" -eq 0 ] && [ -n "${_result}" ]
    then
        _reldate=$(printf '%s' "${_result}" | jq -r '.reldate')
        _bluray_url=$(printf '%s' "${_result}" | jq -r '.url')
        _bluray_title=$(printf '%s' "${_result}" | jq -r '.title')

        debug_log "  Found: ${_reldate} (${_bluray_title})"

        _tmdb_url="https://www.themoviedb.org/movie/${_tmdb_id}"

        _entry=$(jq -n \
            --argjson radarr_id "${_radarr_id}" \
            --arg title "${_title}" \
            --argjson year "${_year}" \
            --argjson tmdb_id "${_tmdb_id}" \
            --arg physical_date "${_reldate}" \
            --arg bluray_title "${_bluray_title}" \
            --arg bluray_url "${_bluray_url}" \
            --arg tmdb_url "${_tmdb_url}" \
            '{radarr_id: $radarr_id, title: $title, year: $year, tmdb_id: $tmdb_id, physical_date: $physical_date, bluray_title: $bluray_title, bluray_url: $bluray_url, tmdb_url: $tmdb_url}')

        _RESULTS=$(printf '%s' "${_RESULTS}" | jq --argjson entry "${_entry}" '. + [$entry]')
        _FOUND_COUNT=$((_FOUND_COUNT + 1))
    fi

    sleep "${BLURAY_RATE_LIMIT}"
done < "${_TEMP}"

rm -f "${_TEMP}"
trap - INT TERM EXIT

##############################################################################
# Phase 3: Output
##############################################################################

if [ "${_FLAG_JSON}" = "true" ]
then
    printf '%s' "${_RESULTS}" | jq \
        --argjson checked "${_CHECKED_COUNT}" \
        --argjson found "${_FOUND_COUNT}" \
        '{movies_checked: $checked, dates_found: $found, results: .}'
    echo
    exit 0
fi

if [ "${_FLAG_QUIET}" = "false" ]
then
    echo
    echo "Physical Release Date Lookup"
    echo "============================"
    echo
    echo "Checked: ${_CHECKED_COUNT} movies"
    echo "Found:   ${_FOUND_COUNT} dates"
    echo

    if [ "${_FOUND_COUNT}" -gt 0 ]
    then
        printf '%-45s %-6s %-15s  %-10s  %s\n' "Movie" "Year" "Blu-ray.com Date" "TMDB ID" "TMDB URL"
        printf '%-45s %-6s %-15s  %-10s  %s\n' "-----" "----" "----------------" "-------" "--------"

        printf '%s' "${_RESULTS}" | jq -r '.[] | "\(.title)|\(.year)|\(.physical_date)|\(.tmdb_id)|\(.tmdb_url)"' | \
        while IFS='|' read -r _title _year _date _tmdb_id _tmdb_url; do
            printf '%-45s %-6s %-15s  %-10s  %s\n' "${_title}" "${_year}" "${_date}" "${_tmdb_id}" "${_tmdb_url}"
        done
        echo
    fi
fi

if [ -n "${_EXPORT_FILE}" ]
then
    if [ "${_FLAG_CSV}" = "true" ]
    then
        echo "radarr_id,title,year,tmdb_id,physical_date,bluray_title,bluray_url,tmdb_url" > "${_EXPORT_FILE}"
        printf '%s' "${_RESULTS}" | jq -r '.[] | [.radarr_id, .title, .year, .tmdb_id, .physical_date, .bluray_title, .bluray_url, .tmdb_url] | @csv' >> "${_EXPORT_FILE}"
        debug_log "Exported ${_FOUND_COUNT} results to ${_EXPORT_FILE} (CSV)"
    else
        printf '%s' "${_RESULTS}" | jq \
            --argjson checked "${_CHECKED_COUNT}" \
            --argjson found "${_FOUND_COUNT}" \
            '{movies_checked: $checked, dates_found: $found, results: .}' > "${_EXPORT_FILE}"
        debug_log "Exported ${_FOUND_COUNT} results to ${_EXPORT_FILE} (JSON)"
    fi

    if [ "${_FLAG_QUIET}" = "false" ]
    then
        echo "Exported to: ${_EXPORT_FILE}"
        echo
    fi
fi

exit 0
