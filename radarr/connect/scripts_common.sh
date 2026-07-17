#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Shared library for arr_scripts connect scripts.
# Sourced by tag_dvfelmel.sh, download_trailer.sh, and auto quality switch scripts.
# Provides: load_config, check_needed_executables, radarr_api_get, get_movie_info,
#           debug_log, get_tag_id_by_label, create_tag, movie_has_tag,
#           add_tag_to_movie, remove_tag_from_movie, _resolve_profile_id

load_config() {
    # Read config from file if found.
    # Accepts optional config directory as $1.
    # Defaults to directory of the invoking script ($0).
    # NOTE: sourcing executes arbitrary shell from scripts.conf; acceptable because
    # the file is gitignored, user-owned, and only readable by the script operator.
    local _config_dir
    _config_dir="${1:-$(dirname "$0")}"

    if [ -f "${_config_dir}/scripts.conf" ]
    then
        . "${_config_dir}/scripts.conf"
    fi

    # Set defaults
    : "${RADARR_API_URL:=http://ip:7878/api/v3}"
    : "${RADARR_API_KEY:=youreallythoughtiwouldputithereright}"
}

check_needed_executables() {
    # Takes a space-delimited list of executables as argument
    local _executable
    for _executable in $1
    do
        if ! command -v "${_executable}" >/dev/null 2>&1
        then
            echo "ERROR: Executable '${_executable}' not found." >&2
            exit 127
        fi
    done
}

radarr_api_get() {
    # Performs a GET to ${RADARR_API_URL}/${1} with X-Api-Key header
    # Returns raw JSON output
    curl \
        -s \
        -H "Accept-Encoding: application/json" \
        -H "X-Api-Key: ${RADARR_API_KEY}" \
        "${RADARR_API_URL}/$1"
}

get_movie_info() {
    # Fetches movie JSON from Radarr by movie ID
    # Returns the movie JSON object
    local _movie_id

    case "$1" in
        ''|*[!0-9]*)
            echo "ERROR: Argument is not a movie id: $1" >&2
            return 1
            ;;
        *)
            _movie_id="$1"
            ;;
    esac

    radarr_api_get "movie/${_movie_id}"
}

debug_log() {
    [ "${DEBUG}" = "true" ] && echo "DEBUG: $*" >&2
}

##############################################################################
# Tag functions (used by tag_dvfelmel.sh and auto quality switch scripts)
##############################################################################

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

add_tag_to_movie() {
    local _movie_id _tag_id _payload _add_tag_response

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
        _payload=$(printf '{"movieIds": [%s], "tags": [%s], "applyTags": "add"}' \
            "${_movie_id}" "${_tag_id}")
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
    local _movie_id _tag_id _payload _remove_tag_response

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
        _payload=$(printf '{"movieIds": [%s], "tags": [%s], "applyTags": "remove"}' \
            "${_movie_id}" "${_tag_id}")
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

##############################################################################
# Profile resolution (used by auto quality switch scripts)
##############################################################################

_resolve_profile_id() {
    local _profile_name _profiles _id

    _profile_name="$1"

    if [ -z "${_profile_name}" ]
    then
        echo "ERROR: resolve_profile_id called with empty name" >&2
        return 1
    fi

    _profiles=$(radarr_api_get "qualityProfile")

    if [ -z "${_profiles}" ]
    then
        echo "ERROR: No response from qualityProfile API" >&2
        return 1
    fi

    _id=$(printf '%s' "${_profiles}" | jq -r --arg name "${_profile_name}" \
        '[.[] | select(.name == $name)] | .[0].id // empty')

    if [ -z "${_id}" ]
    then
        echo "ERROR: Quality profile '${_profile_name}' not found" >&2
        echo "ERROR: Available profiles:" >&2
        printf '%s' "${_profiles}" | jq -r '.[].name' | while read -r _line
        do
            echo "ERROR:   ${_line}" >&2
        done
        return 1
    fi

    printf '%s' "${_id}"
}
