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
# * mktemp (tested with mktemp from FreeBSD base, FreeBSD 14.1)
# * curl (tested with 8.10.1)
# * dovi_tool (tested with 2.1.2
# * ffmpeg (tested with 6.1.2
# * grep (tested with BSD grep 2.6.0-FreeBSD)
# * jq (tested with 1.7.1)
#
# Script based on the work by jpalenz77 from the TRaSH discord
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

# global variables, dont edit
_TAG_CACHE=""

_load_tag_cache() {
    _TAG_CACHE=$(radarr_api_get "tag")
}

get_tag_id_by_label() {
    if [ -z "${_TAG_CACHE}" ]
    then
        _load_tag_cache
    fi
    printf '%s' "${_TAG_CACHE}" | \
    jq -r --arg t "$1" '[.[] | select(.label == $t)] | .[0].id // empty'
}

create_tag() {
    local _payload

    _payload=$(printf '{"label": "%s"}' "$1")
    curl \
        -s \
        -X POST \
        -H "Accept-Encoding: application/json" \
        -H "X-Api-Key: ${RADARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "${_payload}" \
        "${RADARR_API_URL}/tag" | \
    jq ".id"
}

movie_has_tag() {
    local _movie_id _tag_id

    # first argument is the movie id.
    # We support id only
    case "$1" in
        ''|*[!0-9]*)
            echo "ERROR: Argument is not a movie id: $1" >&2
            return 1
            ;;
        *)
            _movie_id="$1"
            ;;
    esac

    # tag can be a string (the label) or an integer (the id)
    case "$2" in
        ''|*[!0-9]*)
            _tag_id=$(get_tag_id_by_label "$2")
            ;;
        *)
            _tag_id="$2"
            ;;
    esac

    if [ -z "${_tag_id}" ]
    then
        echo "ERROR: Invalid tag $2" >&2
        return 127
    fi

    radarr_api_get "movie/${_movie_id}" | \
    jq -e ".tags | index(${_tag_id})" >/dev/null
}

extract_moviefile_rpu_summary() {
    local _rpu_summary _rpu_temp_file


    if [ ! -f "$1" ]
    then
        echo "ERROR: Movie file '$1' not found, Exiting." >&2
        return 127
    fi

    _rpu_temp_file=$(mktemp)
    # shellcheck disable=SC2064
    trap 'rm -f "${_rpu_temp_file}"' EXIT INT TERM
    ffmpeg \
        -loglevel error \
        -t 10 \
        -i "$1" \
        -c:v copy \
        -bsf hevc_mp4toannexb \
        -f hevc \
        - < /dev/null 2>/dev/null | \
    dovi_tool \
        extract-rpu \
        --input - \
        --rpu-out "${_rpu_temp_file}" \
        2>/dev/null

    # ffmpeg and dovi_tool run in a pipeline; without pipefail we cannot
    # trust the pipeline's exit status, so verify the output file instead.
    if [ ! -s "${_rpu_temp_file}" ]
    then
        _rpu_summary=""
    fi

    if [ -s "${_rpu_temp_file}" ] && ! _rpu_summary=$(dovi_tool \
        info \
        --input "${_rpu_temp_file}" \
        --summary \
        2>/dev/null)
    then
        _rpu_summary=""
    fi

    # remove temp file
    if [ -f "${_rpu_temp_file}" ]
    then
        rm "${_rpu_temp_file}"
    fi

    if [ -z "${_rpu_summary}" ]
    then
        echo "ERROR: No RPU data extracted from movie file '$1'" >&2
        trap - EXIT INT TERM
        return 1
    fi

    trap - EXIT INT TERM
    echo "${_rpu_summary}"
}

add_tag_to_movie() {
    local _movie_id _tag_id _payload _add_tag_response

    # first argument is the movie id.
    # We support id only
    case "$1" in
        ''|*[!0-9]*)
            echo "ERROR: Argument is not a movie id: $1" >&2
            return 1
            ;;
        *)
            _movie_id="$1"
            ;;
    esac

    # tag can be a string (the label) or an integer (the id)
    case "$2" in
        ''|*[!0-9]*)
            _tag_id=$(get_tag_id_by_label "$2")
            ;;
        *)
            _tag_id="$2"
            ;;
    esac

    # create tag if it does not exist
    if [ -z "${_tag_id}" ]
    then
        _tag_id=$(create_tag "$2")
        # invalidate cache so subsequent label lookups find the new tag
        _TAG_CACHE=""
    fi

    if ! movie_has_tag "${_movie_id}" "${_tag_id}"
    then
        _payload=$(printf '{"movieIds": [%s], "tags": [%s], "applyTags": "add"}' "${_movie_id}" "${_tag_id}")
        if ! _add_tag_response=$(curl \
            -s \
            -X PUT \
            -H "Accept-Encoding: application/json" \
            -H "X-Api-Key: ${RADARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "${_payload}" \
            "${RADARR_API_URL}/movie/editor")
        then
            echo "ERROR: Payload: ${_payload}" >&2
            echo "ERROR: Response: ${_add_tag_response}" >&2
            return 1
        fi
    fi
}

remove_tag_from_movie() {
    local _movie_id _tag_label _tag_id _payload _remove_tag_response

    # first argument is the movie id.
    # We support id only
    case "$1" in
        ''|*[!0-9]*)
            echo "ERROR: Argument is not a movie id: $1" >&2
            return 1
            ;;
        *)
            _movie_id="$1"
            ;;
    esac

    # tag can be a string (the label) or an integer (the id)
    case "$2" in
        ''|*[!0-9]*)
            _tag_id=$(get_tag_id_by_label "$2")
            ;;
        *)
            _tag_id="$2"
            ;;
    esac

    # if the tag does not exist in radarr, no need to
    # unlink it from the movie ;P
    if [ -z "${_tag_id}" ]
    then
        return 127
    fi

    if movie_has_tag "${_movie_id}" "${_tag_id}"
    then
        _payload=$(printf '{"movieIds": [%s], "tags": [%s], "applyTags": "remove"}' "${_movie_id}" "${_tag_id}")
        if ! _remove_tag_response=$(curl \
            -s \
            -X PUT \
            -H "Accept-Encoding: application/json" \
            -H "X-Api-Key: ${RADARR_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "${_payload}" \
            "${RADARR_API_URL}/movie/editor")
        then
            echo "ERROR: Payload: ${_payload}" >&2
            echo "ERROR: Response: ${_remove_tag_response}" >&2
            return 1
        fi
    fi
}

tag_movie() {
    local _movie_id _movie_file _rpu_summary

    _movie_id="$1"
    _movie_file="$2"

    if ! _rpu_summary=$(extract_moviefile_rpu_summary "${_movie_file}")
    then
        echo "ERROR: Something went wrong trying to extract the needed information from the movie file" >&2
        # We can assume that the file has no RPU data, so no MEL/FEL, so delete the tag if its there
        remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
        remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
        return 1
    fi

    if echo "${_rpu_summary}" | grep -q "Profile: 7 (FEL)"
    then
        debug_log "FEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
        echo "${_rpu_summary}"
        if [ "${DRY_RUN}" = "true" ]
        then
            echo "DRY-RUN: Would add FEL tag, remove MEL tag for movie ${_movie_id}" >&2
        else
            remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
            add_tag_to_movie "${_movie_id}" "${RADARR_TAG_FEL}"
        fi
    elif echo "${_rpu_summary}" | grep -q "Profile: 7 (MEL)"
    then
        debug_log "MEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
        echo "${_rpu_summary}"
        if [ "${DRY_RUN}" = "true" ]
        then
            echo "DRY-RUN: Would add MEL tag, remove FEL tag for movie ${_movie_id}" >&2
        else
            remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
            add_tag_to_movie "${_movie_id}" "${RADARR_TAG_MEL}"
        fi
    else
        debug_log "No FEL nor MEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
        if [ "${DRY_RUN}" = "true" ]
        then
            echo "DRY-RUN: Would remove FEL and MEL tags for movie ${_movie_id}" >&2
        else
            remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
            remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
        fi
    fi
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
check_needed_executables "curl dovi_tool ffmpeg grep jq mktemp"

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
