#!/usr/bin/env sh
# Dont warn on the word `local` or non-constant source
# shellcheck disable=SC1090,SC3043

# Shared library for arr_scripts connect scripts.
# Sourced by tag_dvfelmel.sh, download_trailer.sh, and auto quality switch scripts.
# Provides: load_config, check_needed_executables, radarr_api_get, sonarr_api_get,
#           get_movie_info, get_series_info, debug_log, lang_to_iso639_1,
#           sanitize_filename, notify_autopulse, get_tag_id_by_label, create_tag,
#           movie_has_tag, add_tag_to_movie, remove_tag_from_movie, _resolve_profile_id

load_config() {
    # Read config from file if found.
    # Accepts optional app config directory as $1.
    # Defaults to directory of the invoking script ($0).
    # Sources the shared common/scripts.conf first, then the app config
    # ($1/scripts.conf), so per-app values override shared ones.
    # Migration fallback: if neither new config exists, checks old
    # radarr/connect/scripts.conf path. This fallback will be removed
    # in a future update — migrate with radarr/migrate_config.sh.
    # NOTE: sourcing executes arbitrary shell from scripts.conf; acceptable because
    # the file is gitignored, user-owned, and only readable by the script operator.
    local _config_dir _app_dir _common_conf _loaded _old_conf
    _config_dir="${1:-$(dirname "$0")}"
    _app_dir=$(cd "${_config_dir}" 2>/dev/null && pwd)

    _common_conf="$(dirname "${_app_dir}")/common/scripts.conf"
    _loaded=false
    if [ -n "${_app_dir}" ] && [ -f "${_common_conf}" ]
    then
        . "${_common_conf}"
        _loaded=true
    fi

    if [ -f "${_config_dir}/scripts.conf" ]
    then
        . "${_config_dir}/scripts.conf"
        _loaded=true
    fi

    # Migration fallback: old connect/scripts.conf path
    if [ "${_loaded}" = false ]
    then
        _old_conf="${_app_dir}/connect/scripts.conf"
        if [ -f "${_old_conf}" ]
        then
            echo "WARNING: Config at old path '${_old_conf}'." >&2
            echo "  Migrate: cp '${_old_conf}' '${_app_dir}/scripts.conf" >&2
            echo "  Fallback will be removed in a future update." >&2
            . "${_old_conf}"
        fi
    fi

    # Set defaults
    : "${RADARR_API_URL:=http://ip:7878/api/v3}"
    : "${RADARR_API_KEY:=youreallythoughtiwouldputithereright}"
    : "${SONARR_API_URL:=http://ip:8989/api/v3}"
    : "${SONARR_API_KEY:=youreallythoughtiwouldputithereright}"
    : "${TMDB_API_KEY:=}"
    : "${YT_DLP_COOKIE_FILE:=}"
    : "${YT_DLP_FORMAT:=bv*[height<=1080][vcodec^=avc1]+ba[acodec^=mp4a]/b[height<=1080][vcodec^=avc1]}"
    : "${AUTOPULSE_URL:=}"
    : "${AUTOPULSE_TRIGGER:=manual}"
    : "${AUTOPULSE_AUTH_USER:=}"
    : "${AUTOPULSE_AUTH_PASS:=}"
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

sonarr_api_get() {
    # Performs a GET to ${SONARR_API_URL}/${1} with X-Api-Key header
    # Returns raw JSON output
    curl \
        -s \
        -H "Accept-Encoding: application/json" \
        -H "X-Api-Key: ${SONARR_API_KEY}" \
        "${SONARR_API_URL}/$1"
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

get_series_info() {
    # Fetches series JSON from Sonarr by series ID
    # Returns the series JSON object
    local _series_id

    case "$1" in
        ''|*[!0-9]*)
            echo "ERROR: Argument is not a series id: $1" >&2
            return 1
            ;;
        *)
            _series_id="$1"
            ;;
    esac

    sonarr_api_get "series/${_series_id}"
}

debug_log() {
    [ "${DEBUG}" = "true" ] && echo "DEBUG: $*" >&2
}

# Map ISO 639-2 (3-letter) to ISO 639-1 (2-letter) for common languages
lang_to_iso639_1() {
    case "$1" in
        English|eng) echo "en" ;;
        Portuguese|por) echo "pt" ;;
        Japanese|jpn) echo "ja" ;;
        French|fra|fre) echo "fr" ;;
        German|deu|ger) echo "de" ;;
        Italian|ita) echo "it" ;;
        Spanish|spa) echo "es" ;;
        Korean|kor) echo "ko" ;;
        Chinese|chi|zho) echo "zh" ;;
        Russian|rus) echo "ru" ;;
        Hindi|hin) echo "hi" ;;
        Arabic|ara) echo "ar" ;;
        Turkish|tur) echo "tr" ;;
        Dutch|nld|dut) echo "nl" ;;
        Swedish|swe) echo "sv" ;;
        Norwegian|nor) echo "no" ;;
        Danish|dan) echo "da" ;;
        Finnish|fin) echo "fi" ;;
        Polish|pol) echo "pl" ;;
        Greek|ell|gre) echo "el" ;;
        Hebrew|heb) echo "he" ;;
        Thai|tha) echo "th" ;;
        Vietnamese|vie) echo "vi" ;;
        Indonesian|ind) echo "id" ;;
        Malay|mal) echo "ml" ;;
        Tamil|tam) echo "ta" ;;
        Telugu|tel) echo "te" ;;
        Punjabi|pan) echo "pa" ;;
        Persian|fas|per) echo "fa" ;;
        Catalan|cat) echo "ca" ;;
        Czech|cze|ces) echo "cs" ;;
        Hungarian|hun) echo "hu" ;;
        Romanian|ron|rum) echo "ro" ;;
        Ukrainian|ukr) echo "uk" ;;
        Bulgarian|bul) echo "bg" ;;
        Croatian|hrv) echo "hr" ;;
        Serbian|srp) echo "sr" ;;
        Slovak|slk|slo) echo "sk" ;;
        Slovenian|slv) echo "sl" ;;
        Latvian|lav) echo "lv" ;;
        Lithuanian|lit) echo "lt" ;;
        Estonian|est) echo "et" ;;
        *) echo "" ;;
    esac
}

# Sanitize a name for use as a filename. Replaces invalid characters with
# underscores and truncates to 100 characters.
sanitize_filename() {
    local _name

    _name="$1"
    _name=$(printf '%s' "${_name}" | tr '/\\:*?"<>|%' '_')
    _name=$(printf '%s' "${_name}" | cut -c1-100)
    printf '%s' "${_name}"
}

notify_autopulse() {
    [ -z "${AUTOPULSE_URL}" ] && return 0
    local _path _url _auth _response
    _path="$1"
    _url="${AUTOPULSE_URL}/triggers/${AUTOPULSE_TRIGGER}"
    _auth=""
    [ -n "${AUTOPULSE_AUTH_USER}" ] && _auth="-u ${AUTOPULSE_AUTH_USER}:${AUTOPULSE_AUTH_PASS}"
    debug_log "Notifying autopulse: ${_path}"
    # shellcheck disable=SC2086
    _response=$(curl -s -w "\n%{http_code}" ${_auth} --get \
        --data-urlencode "path=${_path}" \
        "${_url}")
    _curl_rc=$?
    _http_code=$(printf '%s' "${_response}" | tail -1)
    _body=$(printf '%s' "${_response}" | sed '$d')
    case "${_http_code}" in
        2*) debug_log "Autopulse responded: ${_http_code}" ;;
        *) echo "WARN: Autopulse notification failed (HTTP ${_http_code}, curl exit ${_curl_rc}): ${_body}" >&2 ;;
    esac
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
