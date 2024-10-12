#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Script to tag newly imported/upgraded movies
# with 'fel' or 'mel' depending on their DolbyVision
# profile 7 mel or fel availability.
# When a movie in radarr already has this tag, but te new
# file does not have mel nor fel, remove the tag
#
# Requirements:
# * ffmpeg (tested with 6.1.2
# * dovi_tool (tested with 2.1.2
#
# Script based on the work by jpalenz77 from the TRaSH discord
#
# Version 0.0.1 (Released 2024-10-09)
#   * Initial implementation
#     * ffmpeg/dovi_tools output parsing taken from jpalenz77's script
#     * radarr tag functions taken from jpalenz77's script

# Configuration
# Read from file if found
# TODO: Insecure reading of file. Should be moved to a shlib function
SCRIPT_DIR=$(dirname "$0")
if [ -f "${SCRIPT_DIR}/scripts.conf" ]
then
    . "${SCRIPT_DIR}/scripts.conf"
fi

# Set defaults
: "${LOG_FILE:=none}" # If 'none' log to stdout/stderr
: "${RADARR_API_URL:=http://ip:7878/api/v3}"
: "${RADARR_API_KEY:=youreallythoughtiwouldputithereright}"
: "${RADARR_TAG_FEL:=fel}"
: "${RADARR_TAG_MEL:=mel}"

# Information set on the environment by radarr
# Can be overridden by command line arguments:
# $0 <event_type> <movie_id> [movie file path]
# Use defaults to mimic a Test event from radarr
EVENT_TYPE="${radarr_eventtype:-"Test"}"
MOVIE_ID="${radarr_movie_id:-0}"
MOVIE_FILE="${radarr_moviefile_path:-""}"

# global variables, dont edit
NEEDED_EXECUTABLES="curl jq ffmpeg dovi_tool grep mktemp"

check_needed_executables() {
    for executable in ${NEEDED_EXECUTABLES}
    do
        if ! command -v "${executable}" >/dev/null 2>&1
        then
            echo "ERROR: Executable '${executable} not found." >&2
            exit 127
        fi
    done
}

get_tag_id_by_label() {
    curl \
        -s \
        -H "Accept-Encoding: application/json" \
        "${RADARR_API_URL}/tag?apikey=${RADARR_API_KEY}" | \
    jq ".[] | select(.label == \"$1\") | .id"
}

create_tag() {
    local _payload

    _payload=$(printf '{"label": "%s"}' "$1")
    curl \
        -s \
        -X POST \
        -H "Accept-Encoding: application/json" \
        -H "Content-Type: application/json" \
        -d "${_payload}" \
        "${RADARR_API_URL}/tag?apikey=${RADARR_API_KEY}" | \
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

    curl \
        -s \
        -H "Accept-Encoding: application/json" \
        "${RADARR_API_URL}/movie/$1?apikey=${RADARR_API_KEY}" | \
    jq -e ".tags | index(${_tag_id})" >/dev/null
}

extract_moviefile_rpu_info() {
    local _rpu_summary _rpu_temp_file


    if [ ! -f "$1" ]
    then
        echo "ERROR: Movie file '$1' not found, Exiting." >&2
        return 127
    fi

    _rpu_temp_file=$(mktemp -t radarr_rpu_info)
    if ! ffmpeg \
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
    then
        _rpu_summary=""
    fi

    if ! _rpu_summary=$(dovi_tool \
        info \
        --input "${_rpu_temp_file}" \
        --summary \
        2>/dev/null)
    then
        _rpu_summary=""
    fi

    # remove temp filee
    if [ -f "${_rpu_temp_file}" ]
    then
        rm "${_rpu_temp_file}"
    fi

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
    fi

    if ! movie_has_tag "${_movie_id}" "${_tag_id}"
    then
        _payload=$(printf '{"movieIds": [%s], "tags": [%s], "applyTags": "add"}' "${_movie_id}" "${_tag_id}")
        if ! _add_tag_response=$(curl \
            -s \
            -X PUT \
            -H "Accept-Encoding: application/json" \
            -H "Content-Type: application/json" \
            -d "${_payload}" \
            "${RADARR_API_URL}/movie/editor?apikey=${RADARR_API_KEY}")
        then
            echo "ERROR: Payload: ${_payload}" >&2
            echo "ERROR: Response: ${_add_tag_response}" >&2
            return 1
        fi
    fi
}

remove_tag_from_movie() {
    local _movie_id _tag_label _payload _remove_tag_response

    # first argument is the movie id.
    # We support id only
    case "$1" in
        ''|*[!0-9]*)
            echo "ERROR: Argument is not a movie id: $1" >&2
            return 1
            ;;
        *)
            _movie_id="$1"
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
            -H "Content-Type: application/json" \
            -d "${_payload}" \
            "${RADARR_API_URL}/movie/editor?apikey=${RADARR_API_KEY}")
        then
            echo "ERROR: Payload: ${_payload}" >&2
            echo "ERROR: Response: ${_add_tag_response}" >&2
            return 1
        fi
    fi
}

tag_movie() {
    local _movie_id _movie_file

    _movie_id="$1"
    _movie_file="$2"

    if ! rpu_info=$(extract_moviefile_rpu_info "${_movie_file}")
    then
        echo "ERROR: Something went wrong trying to extract the needed information from the movie file" >&2
        # We can assume that the file has no RPU data, so no MEL/FEL, so delete the tag if its there
        remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
        remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
        return 1
    fi

    if echo "${rpu_info}" | grep -qi "FEL"
    then
        echo "DEBUG: FEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
        add_tag_to_movie "${_movie_id}" "${RADARR_TAG_FEL}"
    elif echo "${rpu_info}" | grep -qi "MEL"
    then
        echo "DEBUG: MEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
        add_tag_to_movie "${_movie_id}" "${RADARR_TAG_MEL}"
    else
        echo "DEBUG: No FEL nor MEL detected for movie (id: ${_movie_id}, file: ${_movie_file})"
        remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_FEL}"
        remove_tag_from_movie "${_movie_id}" "${RADARR_TAG_MEL}"
    fi
}

tag_all_movies() {
    curl \
        -s \
        -H "Accept-Encoding: application/json" \
        "${RADARR_API_URL}/movie?apikey=${RADARR_API_KEY}" | \
    jq -r 'sort_by(.id)[] | select(.movieFile != null) | "\(.id) \(.movieFile.path)"' | \
    while read -r id file; do
        echo "DEBUG: Tagging movie '${id}' with path '${file}'"
        tag_movie "$id" "$file"
    done
}

# main script flow
check_needed_executables

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
        echo "DEBUG: Received test event, signal success"
        exit 0
        ;;
    MovieFileDelete)
        echo "DEBUG: Got event ${EVENT_TYPE}, handling"
        # On file delete, we should delete the tags if they are attached
        remove_tag_from_movie "${MOVIE_ID}" "${RADARR_TAG_FEL}"
        remove_tag_from_movie "${MOVIE_ID}" "${RADARR_TAG_MEL}"
        exit 0
        ;;
    Download)
        echo "DEBUG: Got event ${EVENT_TYPE}, handling"
        tag_movie "${MOVIE_ID}" "${MOVIE_FILE}"
        ;;
    [Bb]ulk)
        # This event does not exist in radarr, but can be triggered
        # by a cli invokation of this script. eg
        # ./tag_dvfelmel.sh bulk
        echo "DEBUG: Got event ${EVENT_TYPE}, handling"
        tag_all_movies
        ;;
    *)
        echo "ERROR: Got event ${EVENT_TYPE} that cannot be handled, exiting" >&2
        exit 4
        ;;
esac
