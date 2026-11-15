#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Script to tag newly imported/upgraded movies
# with 'fel' or 'mel' depending on their Dolby Vision
# profile 7 mel or fel availability.
# When a movie in radarr already has this tag, but the new
# file does not have mel nor fel, remove the tag
#
# Requirements:
# * sh (tested with sh from FreeBSD base FreeBSD 14.1)
# * curl (tested with 8.10.1)
# * hdrprobe (tested with 0.7.0 and 1.0.1)
# * jq (tested with 1.7.1)
# * mktemp (tested with mktemp from FreeBSD base, FreeBSD 14.1)
#
# Script based on the work by jpalenz77 from the TRaSH discord
#
# Version 0.5.0 (Released 2026-11-15)
#   * Bulk mode prints per-movie progress and a final summary
#   * Bulk mode removes fel/mel tags from movies whose file is gone
#   * Missing movie file removes stale tags instead of reporting a probe error
#   * Dry-run also covers tag removal when probing fails
#   * Bulk mode no longer sets dry-run and debug defaults (both were no-ops)
#
# Version 0.4.0 (Released 2026-07-23)
#   * Replace ffmpeg+dovi_tool+grep chain with hdrprobe
#   * Single binary, no temp files, JSON output
#   * Correctly handles multi-track files via el_type iteration
#
# Version 0.3.0 (Released 2026-06-30)
#   * DRY_RUN and DEBUG config variables with -n/-d CLI flags
#   * Bulk mode enables dry-run and debug by default
#   * Dry-run skips add/remove tag API calls
#   * debug_log function gates DEBUG output
#
# Version 0.2.0 (Released 2026-06-30)
#   * Cache tag ids to reduce api calls
#
# Version 0.1.0 (Released 2026-06-30)
#   * Add bulk event type to tag all movies in radarr
#   * Move main logic into functions for reuse
#   * Remove fel/mel tags that no longer apply on import/delete
#   * Pass API key via header instead of URL query string
#   * Verify RPU temp file output instead of unreliable pipeline exit status
#   * Return non-zero when RPU extraction yields no summary
#   * Trap signals to clean up temp file during RPU extraction
#   * Use portable integer sleep duration
#   * Guard against duplicate tag labels in get_tag_id_by_label
#   * Use jq --arg to safely interpolate tag labels
#   * Run bulk-tagging loop in current shell to preserve counter
#   * Normalize case branch terminators and validated variable usage
#   * Fix typos in comments and README
#
# Version 0.0.1 (Released 2024-10-09)
#   * Initial implementation
#     * ffmpeg/dovi_tools output parsing taken from jpalenz77's script
#     * radarr tag functions taken from jpalenz77's script
#
# For information on how to get this script to work inside a radarr docker container please
# have a look at https://discord.com/channels/492590071455940612/1327957617661972510/1327957617661972510
# The fine folks in the TRaSH-Guides discord have it figured out. Thanks for sharing!

# Load shared library and configuration
. "$(dirname "$0")/../../common/scripts_common.sh"
load_config "$(dirname "$0")/.."

# Tag-specific defaults
: "${LOG_FILE:=none}" # If 'none' log to stdout/stderr
: "${RADARR_TAG_FEL:=fel}"
: "${RADARR_TAG_MEL:=mel}"
: "${DRY_RUN:=false}"
: "${DEBUG:=false}"

# Information set on the environment by radarr
# Can be overridden by command line arguments:
# $0 <event_type> <movie_id> [movie file path]
# Use defaults to mimic a Test event from radarr
EVENT_TYPE="${radarr_eventtype:-"Test"}"
MOVIE_ID="${radarr_movie_id:-0}"
MOVIE_FILE="${radarr_moviefile_path:-""}"

# Outcome of the last tag_movie call: fel, mel, none, stale or error
TAG_RESULT=""

apply_change() {
    # Runs the tag change given as remaining arguments,
    # or reports it when running in dry-run mode.
    local _description

    _description="$1"
    shift
    if [ "${DRY_RUN}" = "true" ]
    then
        echo "DRY-RUN: Would ${_description}" >&2
    else
        "$@"
    fi
}

probe_dv_el_type() {
    local _hdrprobe_output _el_type

    if [ ! -f "$1" ]
    then
        echo "ERROR: Movie file '$1' not found, Exiting." >&2
        return 127
    fi

    _hdrprobe_output=$(hdrprobe --json --sections dv "$1" 2>/dev/null)

    if [ -z "${_hdrprobe_output}" ]
    then
        echo "ERROR: hdrprobe failed for movie file '$1'" >&2
        return 1
    fi

    # Resolve highest-priority el_type across all video tracks.
    # FEL wins over MEL. Returns "FEL", "MEL", or empty.
    _el_type=$(printf '%s' "${_hdrprobe_output}" | \
        jq -r '[
            .video_tracks[] | .dolby_vision.el_type // empty
        ] | if any(. == "FEL") then "FEL"
            elif any(. == "MEL") then "MEL"
            else empty
            end')

    if [ -z "${_el_type}" ]
    then
        return 1
    fi

    printf '%s' "${_el_type}"
}

tag_movie() {
    local _movie_id _movie_file _el_type _probe_rc

    _movie_id="$1"
    _movie_file="$2"
    TAG_RESULT="error"

    if [ -z "${_movie_file}" ] || [ ! -f "${_movie_file}" ]
    then
        debug_log "Movie file missing for movie (id: ${_movie_id})"
        TAG_RESULT="stale"
        apply_change "remove tag '${RADARR_TAG_FEL}' for movie ${_movie_id}" \
            remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
        apply_change "remove tag '${RADARR_TAG_MEL}' for movie ${_movie_id}" \
            remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
        return 0
    fi

    _el_type=$(probe_dv_el_type "${_movie_file}")
    _probe_rc=$?

    if [ "${_probe_rc}" -ne 0 ] && [ "${_probe_rc}" -ne 1 ]
    then
        echo "ERROR: Something went wrong trying to probe '${_movie_file}'" >&2
        apply_change "remove tag '${RADARR_TAG_FEL}' for movie ${_movie_id}" \
            remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
        apply_change "remove tag '${RADARR_TAG_MEL}' for movie ${_movie_id}" \
            remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
        return 1
    fi

    case "${_el_type}" in
        FEL)
            TAG_RESULT="fel"
            debug_log "FEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
            apply_change "remove tag '${RADARR_TAG_MEL}' for movie ${_movie_id}" \
                remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
            apply_change "add tag '${RADARR_TAG_FEL}' for movie ${_movie_id}" \
                add_tag_to_movie "${_movie_id}" "${RADARR_TAG_FEL}"
            ;;
        MEL)
            TAG_RESULT="mel"
            debug_log "MEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
            apply_change "remove tag '${RADARR_TAG_FEL}' for movie ${_movie_id}" \
                remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
            apply_change "add tag '${RADARR_TAG_MEL}' for movie ${_movie_id}" \
                add_tag_to_movie "${_movie_id}" "${RADARR_TAG_MEL}"
            ;;
        *)
            TAG_RESULT="none"
            debug_log "No FEL nor MEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
            apply_change "remove tag '${RADARR_TAG_FEL}' for movie ${_movie_id}" \
                remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
            apply_change "remove tag '${RADARR_TAG_MEL}' for movie ${_movie_id}" \
                remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
            ;;
    esac
}

tag_all_movies() {
    local _counter _total _percent _fel _mel _none _stale _errors
    local _fel_tag_id _mel_tag_id _movies_json _work_filter
    local _movie_list _movie_id _movie_title _movie_file

    _counter=0
    _fel=0
    _mel=0
    _none=0
    _stale=0
    _errors=0

    _fel_tag_id=$(get_tag_id_by_label "${RADARR_TAG_FEL}")
    _mel_tag_id=$(get_tag_id_by_label "${RADARR_TAG_MEL}")

    # Movies without a file are only included when they still carry a tag,
    # so stale tags from deleted files get cleaned up.
    # shellcheck disable=SC2016 # $fel and $mel are jq variables, not shell ones
    _work_filter='sort_by(.id)[]
    | select(.movieFile != null or ((.tags // []) | any(. == $fel or . == $mel)))'

    _movies_json=$(radarr_api_get "movie")
    if [ -z "${_movies_json}" ]
    then
        echo "ERROR: No response from radarr movie API" >&2
        return 1
    fi

    _total=$(printf '%s' "${_movies_json}" | \
        jq --argjson fel "${_fel_tag_id:-0}" --argjson mel "${_mel_tag_id:-0}" \
        "[${_work_filter}] | length")

    if [ "${_total}" -eq 0 ]
    then
        echo "Bulk: nothing to process" >&2
        return 0
    fi

    _movie_list=$(printf '%s' "${_movies_json}" | \
        jq -r --argjson fel "${_fel_tag_id:-0}" --argjson mel "${_mel_tag_id:-0}" \
        "${_work_filter} | [(.id|tostring), .title, (.movieFile.path // \"\")] | @tsv")

    while IFS="$(printf '\t')" read -r _movie_id _movie_title _movie_file
    do
        _counter=$((_counter+=1))
        _percent=$((_counter * 100 / _total))
        tag_movie "${_movie_id}" "${_movie_file}"
        printf '[%4d/%4d] %3d%%  #%s  %-5s  %s\n' \
            "${_counter}" "${_total}" "${_percent}" \
            "${_movie_id}" "${TAG_RESULT}" "${_movie_title}" >&2
        case "${TAG_RESULT}" in
            fel) _fel=$((_fel+=1)) ;;
            mel) _mel=$((_mel+=1)) ;;
            none) _none=$((_none+=1)) ;;
            stale) _stale=$((_stale+=1)) ;;
            *) _errors=$((_errors+=1)) ;;
        esac
        # lame, but be nice to our radarr api
        sleep 1
    done <<EOF
${_movie_list}
EOF

    printf 'Bulk: %d processed, fel %d, mel %d, none %d, stale %d, errors %d\n' \
        "${_total}" "${_fel}" "${_mel}" "${_none}" "${_stale}" "${_errors}" >&2
}

# main script flow
check_needed_executables "curl hdrprobe jq mktemp"

# Parse optional flags before positional args
while [ $# -gt 0 ]; do
    case "$1" in
        -n) DRY_RUN=true; shift ;;
        -d) DEBUG=true; shift ;;
        -h|--help)
            echo "Usage: $0 [-n] [-d] [event_type] [movie_id] [movie_file_path]"
            echo ""
            echo "Tag movies with 'fel' or 'mel' based on Dolby Vision Enhancement Layer."
            echo ""
            echo "Options:"
            echo "  -n    Dry-run mode"
            echo "  -d    Debug logging"
            echo "  -h    Show this help"
            echo ""
            echo "Event types: Test, MovieFileDelete, Download, Bulk"
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
    MOVIE_ID="$2"
fi

if [ -n "$3" ]
then
    MOVIE_FILE="$3"
fi

case "${EVENT_TYPE}" in
    Test)
        debug_log "Received test event, signal success"
        exit 0
        ;;
    MovieFileDelete)
        debug_log "Got event ${EVENT_TYPE}, handling"
        # On file delete, we should delete the tags if they are attached
        apply_change "remove tag '${RADARR_TAG_FEL}' for movie ${MOVIE_ID}" \
            remove_tag_from_movie "${MOVIE_ID}" "${RADARR_TAG_FEL}"
        apply_change "remove tag '${RADARR_TAG_MEL}' for movie ${MOVIE_ID}" \
            remove_tag_from_movie "${MOVIE_ID}" "${RADARR_TAG_MEL}"
        exit 0
        ;;
    Download)
        debug_log "Got event ${EVENT_TYPE}, handling"
        tag_movie "${MOVIE_ID}" "${MOVIE_FILE}"
        ;;
    [Bb]ulk)
        # This event does not exist in radarr, but can be triggered
        # by a cli invokation of this script. eg
        # ./tag_dvfelmel.sh bulk
        debug_log "Got event ${EVENT_TYPE}, handling"
        tag_all_movies
        ;;
    *)
        echo "ERROR: Got event ${EVENT_TYPE} that cannot be handled, exiting" >&2
        exit 4
        ;;
esac
