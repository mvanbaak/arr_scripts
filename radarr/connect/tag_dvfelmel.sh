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
# * hdrprobe (tested with 0.7.0)
# * jq (tested with 1.7.1)
# * mktemp (tested with mktemp from FreeBSD base, FreeBSD 14.1)
#
# Script based on the work by jpalenz77 from the TRaSH discord
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
. "$(dirname "$0")/scripts_common.sh"
load_config

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

    _el_type=$(probe_dv_el_type "${_movie_file}")
    _probe_rc=$?

    if [ "${_probe_rc}" -ne 0 ] && [ "${_probe_rc}" -ne 1 ]
    then
        echo "ERROR: Something went wrong trying to probe the movie file" >&2
        remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
        remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
        return 1
    fi

    case "${_el_type}" in
        FEL)
            debug_log "FEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
            if [ "${DRY_RUN}" = "true" ]
            then
                echo "DRY-RUN: Would add FEL tag, remove MEL tag for movie ${_movie_id}" >&2
            else
                remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
                add_tag_to_movie "${_movie_id}" "${RADARR_TAG_FEL}"
            fi
            ;;
        MEL)
            debug_log "MEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
            if [ "${DRY_RUN}" = "true" ]
            then
                echo "DRY-RUN: Would add MEL tag, remove FEL tag for movie ${_movie_id}" >&2
            else
                remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
                add_tag_to_movie "${_movie_id}" "${RADARR_TAG_MEL}"
            fi
            ;;
        *)
            debug_log "No FEL nor MEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
            if [ "${DRY_RUN}" = "true" ]
            then
                echo "DRY-RUN: Would remove FEL and MEL tags for movie ${_movie_id}" >&2
            else
                remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
                remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
            fi
            ;;
    esac
}

tag_all_movies() {
    local _counter _movie_list
    _counter=0
    _movie_list=$(radarr_api_get "movie" | \
    jq -r 'sort_by(.id)[] | select(.movieFile != null) | "\(.id) \(.movieFile.path)"')

    while read -r id file; do
        _counter=$((_counter+=1))
        debug_log "(${_counter}) Tagging movie '${id}' with path '${file}'"
        tag_movie "$id" "$file"
        # lame, but be nice to our radarr api
        sleep 1
    done <<EOF
${_movie_list}
EOF
}

# main script flow
check_needed_executables "curl hdrprobe jq mktemp"

# Parse optional flags before positional args
while [ $# -gt 0 ]; do
    case "$1" in
        -n) DRY_RUN=true; shift ;;
        -d) DEBUG=true; shift ;;
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
        if [ "${DRY_RUN}" = "true" ]
        then
            echo "DRY-RUN: Would remove FEL and MEL tags for movie ${MOVIE_ID}" >&2
        else
            # On file delete, we should delete the tags if they are attached
            remove_tag_from_movie "${MOVIE_ID}" "${RADARR_TAG_FEL}"
            remove_tag_from_movie "${MOVIE_ID}" "${RADARR_TAG_MEL}"
        fi
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
        : "${DRY_RUN:=true}"
        : "${DEBUG:=true}"
        debug_log "Got event ${EVENT_TYPE}, handling"
        tag_all_movies
        ;;
    *)
        echo "ERROR: Got event ${EVENT_TYPE} that cannot be handled, exiting" >&2
        exit 4
        ;;
esac
