#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Shared library for arr_scripts connect scripts.
# Sourced by tag_dvfelmel.sh and download_trailer.sh.
# Provides: load_config, check_needed_executables, radarr_api_get, get_movie_info, debug_log

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
