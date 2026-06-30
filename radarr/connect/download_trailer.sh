#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Script to download official trailers for movies in radarr.
# Trailers are sourced from TMDB and downloaded from YouTube via yt-dlp.
# Trailers are stored in a 'Trailers/' subdirectory inside the movie folder.
#
# Requirements:
# * sh (tested with sh from FreeBSD base FreeBSD 14.1)
# * curl (tested with 8.10.1)
# * jq (tested with 1.7.1)
# * mkdir (coreutils / FreeBSD base)
# * mktemp (coreutils / FreeBSD base)
# * yt-dlp (tested with 2024.x.x)
#
# Script based on the tag_dvfelmel.sh structure by Michiel van Baak Jansen
#
# Version 0.2.0 (Released 2026-06-30)
#   * Recode trailers to MP4/H.264 for universal Plex Direct Play
#   * Autopulse notification after download (AUTOPULSE_URL config)
#   * YT_DLP_FORMAT and YT_DLP_RECODE config variables for format control
#   * DRY_RUN and DEBUG config variables with -n/-d CLI flags
#   * Bulk mode enables dry-run and debug by default
#   * Full yt-dlp command shown in dry-run output
#   * Skip directory creation in dry-run mode
#   * Radarr v5 originalLanguage object format support
#   * Full language name mapping (e.g. "English", "French") in lang_to_iso639_1
#   * Handle null iso_639_1 from TMDB in trailer lookup
#
# Version 0.1.0 (Released 2026-06-30)
#   * Initial implementation
#     * TMDB trailer lookup with language filtering
#     * yt-dlp download with per-movie archive tracking
#     * Brazilian Portuguese subtitle support for original-language trailers
#     * Cookie file support for age-restricted content
#     * Bulk mode for backfilling existing library

# Load shared library and configuration
. "$(dirname "$0")/scripts_common.sh"
load_config

# Trailer-specific defaults
: "${TMDB_API_KEY:=}"
: "${TRAILER_LANGUAGES:=original,pt-BR}"
: "${TRAILER_SUBTITLE_LANGS:=pt-BR}"
: "${YT_DLP_COOKIE_FILE:=}"
: "${YT_DLP_FORMAT:=bv*+ba/b}"
: "${YT_DLP_RECODE:=mp4}"
: "${AUTOPULSE_URL:=}"
: "${AUTOPULSE_TRIGGER:=manual}"
: "${AUTOPULSE_AUTH_USER:=}"
: "${AUTOPULSE_AUTH_PASS:=}"
: "${DRY_RUN:=false}"
: "${DEBUG:=false}"

# Information set on the environment by radarr
# Can be overridden by command line arguments:
# $0 <event_type> <movie_id> [movie file path]
# Use defaults to mimic a Test event from radarr
EVENT_TYPE="${radarr_eventtype:-"Test"}"
MOVIE_ID="${radarr_movie_id:-0}"
MOVIE_PATH="${radarr_movie_path:-""}"

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

# Query TMDB for official YouTube trailers for a movie
# Arguments: tmdb_id language_code
# Outputs: lines of "youtube_key|video_name|iso_639_1" for each matching trailer
get_tmdb_trailers() {
    local _tmdb_id _lang _response

    _tmdb_id="$1"
    _lang="$2"

    if [ -z "${TMDB_API_KEY}" ]
    then
        echo "ERROR: TMDB_API_KEY is not set" >&2
        return 1
    fi

    _response=$(curl \
        -s \
        "https://api.themoviedb.org/3/movie/${_tmdb_id}/videos?api_key=${TMDB_API_KEY}&language=${_lang}")

    if [ -z "${_response}" ]
    then
        echo "ERROR: No response from TMDB for movie ${_tmdb_id}, language ${_lang}" >&2
        return 1
    fi

    printf '%s' "${_response}" | \
    jq -r '.results[] | select(.type == "Trailer" and .official == true and .site == "YouTube") | "\(.key)|\(.name | gsub("\\|"; "_"))|\(.iso_639_1 // empty)"'
}

# Sanitize a string for use as a filename
# Removes/replaces characters invalid on Linux/macOS/Windows
# Truncates to 100 characters
sanitize_filename() {
    local _name

    _name="$1"
    # Replace invalid characters with underscores
    _name=$(printf '%s' "${_name}" | tr '/\\:*?"<>|%' '_')
    # Truncate to 100 chars
    _name=$(printf '%s' "${_name}" | cut -c1-100)
    printf '%s' "${_name}"
}

# Download a single trailer via yt-dlp
# Arguments: youtube_key video_name lang_code is_original_lang movie_path
download_trailer() {
    local _yt_key _video_name _lang _is_original _movie_path _trailers_dir _sanitized_name _subtitle_flags _cookie_flags

    _yt_key="$1"
    _video_name="$2"
    _lang="$3"
    _is_original="$4"
    _movie_path="$5"

    _trailers_dir="${_movie_path}/Trailers"
    _sanitized_name=$(sanitize_filename "${_video_name}-${_lang}")

    # Build subtitle flags - only for original-language trailers
    _subtitle_flags=""
    if [ "${_is_original}" = "true" ] && [ -n "${TRAILER_SUBTITLE_LANGS}" ]
    then
        _subtitle_flags="--write-subs --sub-langs ${TRAILER_SUBTITLE_LANGS}"
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
        echo "DRY-RUN: Download '${_video_name}' (${_lang}) → ${_trailers_dir}/${_sanitized_name}.mp4" >&2
        echo "DRY-RUN: yt-dlp --download-archive \"${_trailers_dir}/.archive\" -o \"${_trailers_dir}/${_sanitized_name}.%(ext)s\" -f \"${YT_DLP_FORMAT}\" --recode-video \"${YT_DLP_RECODE}\" ${_subtitle_flags} ${_cookie_flags} \"https://www.youtube.com/watch?v=${_yt_key}\"" >&2
        return 0
    fi

    # Skip if already in yt-dlp archive
    if [ -f "${_trailers_dir}/.archive" ] && grep -qs "${_yt_key}" "${_trailers_dir}/.archive"
    then
        debug_log "Trailer already downloaded, skipping: ${_sanitized_name}"
        return 1
    fi

    debug_log "Downloading trailer '${_video_name}' (${_lang}) for ${_movie_path}"

    # shellcheck disable=SC2086
    yt-dlp \
        --download-archive "${_trailers_dir}/.archive" \
        -o "${_trailers_dir}/${_sanitized_name}.%(ext)s" \
        -f "${YT_DLP_FORMAT}" \
        --recode-video "${YT_DLP_RECODE}" \
        ${_subtitle_flags} \
        ${_cookie_flags} \
        "https://www.youtube.com/watch?v=${_yt_key}"
}

# Process a single movie: look up trailers on TMDB and download them
# Arguments: movie_id movie_path
process_movie() {
    local _movie_id _movie_path _movie_info _tmdb_id _original_lang_3 _original_lang_2
    local _desired_langs _lang _is_original _trailers_temp _trailers_dir
    local _yt_key _video_name _trailer_lang

    _movie_id="$1"
    _movie_path="$2"

    if [ -z "${_movie_id}" ] || [ -z "${_movie_path}" ]
    then
        echo "ERROR: Missing movie_id or movie_path for process_movie" >&2
        return 1
    fi

    # Get movie info from Radarr
    if ! _movie_info=$(get_movie_info "${_movie_id}")
    then
        echo "ERROR: Failed to get movie info for id ${_movie_id}" >&2
        return 1
    fi

    _tmdb_id=$(printf '%s' "${_movie_info}" | jq -r '.tmdbId')
    _original_lang_3=$(printf '%s' "${_movie_info}" | jq -r '.originalLanguage | if type == "object" then (.iso_639_2 // .name) else . end // empty')

    if [ -z "${_tmdb_id}" ]
    then
        debug_log "Movie ${_movie_id} has no tmdbId, skipping"
        return 0
    fi

    # Map original language from ISO 639-2 to ISO 639-1
    _original_lang_2=$(lang_to_iso639_1 "${_original_lang_3}")
    if [ -z "${_original_lang_2}" ]
    then
        echo "WARN: No ISO 639-1 mapping for '${_original_lang_3}', skipping original-language trailers for movie ${_movie_id}" >&2
    fi

    # Build list of desired languages, resolving "original" to the mapped language
    # TRAILER_LANGUAGES is comma-separated, e.g. "original,pt-BR"
    _desired_langs=""
    # shellcheck disable=SC2086
    for _lang in $(printf '%s' "${TRAILER_LANGUAGES}" | tr ',' ' ')
    do
        if [ "${_lang}" = "original" ]
        then
            if [ -n "${_original_lang_2}" ]
            then
                _desired_langs="${_desired_langs} ${_original_lang_2}"
            fi
        else
            _desired_langs="${_desired_langs} ${_lang}"
        fi
    done

    if [ -z "${_desired_langs}" ]
    then
        debug_log "No desired languages to search for movie ${_movie_id}"
        return 0
    fi

    # Query TMDB for trailers in each desired language, save to temp file
    # Using a temp file + while read to correctly handle trailer names with spaces
    # (for _line in ${var} would word-split on spaces and break names like "Official Trailer")
    _trailers_temp=$(mktemp)
    # shellcheck disable=SC2064
    trap 'rm -f "${_trailers_temp}"; exit 130' INT TERM
    trap 'rm -f "${_trailers_temp}"' EXIT

    for _lang in ${_desired_langs}
    do
        if [ "${_lang}" = "${_original_lang_2}" ]
        then
            _is_original="true"
        else
            _is_original="false"
        fi

        # Pipe TMDB results through while read to preserve spaces in names
        # Each line from get_tmdb_trailers is: youtube_key|video_name|iso_639_1
        # We append |is_original to each line
        get_tmdb_trailers "${_tmdb_id}" "${_lang}" | while IFS='|' read -r _yt_key _video_name _trailer_lang _; do
            if [ -n "${_yt_key}" ]
            then
                printf '%s|%s|%s|%s\n' "${_yt_key}" "${_video_name}" "${_trailer_lang}" "${_is_original}"
            fi
        done >> "${_trailers_temp}"
    done

    # Check if we found any trailers
    if [ ! -s "${_trailers_temp}" ]
    then
        debug_log "No trailers found for movie ${_movie_id} (tmdbId: ${_tmdb_id})"
        rm -f "${_trailers_temp}"
        trap - INT TERM EXIT
        return 0
    fi

    # Create directories if needed (skip in dry-run)
    if [ "${DRY_RUN}" = "true" ]
    then
        debug_log "Dry-run: would create directories for ${_movie_path}"
    else
        # Create movie directory if it doesn't exist (MovieAdded case)
        if [ ! -d "${_movie_path}" ]
        then
            if ! mkdir -p "${_movie_path}"
            then
                echo "ERROR: Failed to create movie directory: ${_movie_path}" >&2
                rm -f "${_trailers_temp}"
                trap - INT TERM EXIT
                return 1
            fi
        fi

        # Create Trailers subdirectory
        _trailers_dir="${_movie_path}/Trailers"
        if [ ! -d "${_trailers_dir}" ]
        then
            if ! mkdir -p "${_trailers_dir}"
            then
                echo "ERROR: Failed to create trailers directory: ${_trailers_dir}" >&2
                rm -f "${_trailers_temp}"
                trap - INT TERM EXIT
                return 1
            fi
        fi
    fi

    # Download each trailer, track if anything new was actually downloaded
    _has_new=false
    while IFS='|' read -r _yt_key _video_name _trailer_lang _is_original; do
        if [ -n "${_yt_key}" ]
        then
            download_trailer "${_yt_key}" "${_video_name}" "${_trailer_lang}" "${_is_original}" "${_movie_path}"
            _dl_status=$?
            case $_dl_status in
                0) _has_new=true ;;
                1) debug_log "Skipped, already downloaded" ;;
                *) echo "ERROR: Failed to download trailer ${_yt_key} for movie ${_movie_id}" >&2 ;;
            esac
        fi
    done < "${_trailers_temp}"

    [ "${_has_new}" = "true" ] && [ "${DRY_RUN}" != "true" ] && notify_autopulse "${_movie_path}"
    rm -f "${_trailers_temp}"
    trap - INT TERM EXIT
}

# Process all movies in radarr (bulk/backfill mode)
process_all_movies() {
    local _counter _movie_list _id _path

    _counter=0
    _movie_list=$(radarr_api_get "movie" | \
    jq -r 'sort_by(.id)[] | "\(.id) \(.path)"')

    while read -r _id _path; do
        _counter=$((_counter+1))
        debug_log "(${_counter}) Processing movie '${_id}' with path '${_path}'"
        process_movie "${_id}" "${_path}"
        # Be nice to the TMDB and Radarr APIs
        sleep 1
    done <<EOF
${_movie_list}
EOF
}

debug_log() {
    [ "${DEBUG}" = "true" ] && echo "DEBUG: $*" >&2
}

notify_autopulse() {
    [ -z "${AUTOPULSE_URL}" ] && return 0
    local _path _url _auth
    _path="$1"
    _url="${AUTOPULSE_URL}/triggers/${AUTOPULSE_TRIGGER}"
    _auth=""
    [ -n "${AUTOPULSE_AUTH_USER}" ] && _auth="-u ${AUTOPULSE_AUTH_USER}:${AUTOPULSE_AUTH_PASS}"
    debug_log "Notifying autopulse: ${_path}"
    # shellcheck disable=SC2086
    curl -s ${_auth} --get \
        --data-urlencode "path=${_path}" \
        "${_url}"
}

# main script flow
check_needed_executables "curl cut jq mkdir mktemp tr yt-dlp"

if [ -z "${TMDB_API_KEY}" ]
then
    echo "ERROR: TMDB_API_KEY is not set. Configure it in scripts.conf" >&2
    exit 1
fi

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
    MOVIE_PATH="$3"
fi

case "${EVENT_TYPE}" in
    Test)
        debug_log "Received test event, signal success"
        exit 0
        ;;
    MovieAdded)
        debug_log "Got event ${EVENT_TYPE}, handling"
        process_movie "${MOVIE_ID}" "${MOVIE_PATH}"
        ;;
    Download)
        debug_log "Got event ${EVENT_TYPE}, handling"
        process_movie "${MOVIE_ID}" "${MOVIE_PATH}"
        ;;
    [Bb]ulk)
        # This event does not exist in radarr, but can be triggered
        # by a cli invokation of this script. eg
        # ./download_trailer.sh bulk
        : "${DRY_RUN:=true}"
        : "${DEBUG:=true}"
        debug_log "Got event ${EVENT_TYPE}, handling"
        process_all_movies
        ;;
    *)
        echo "ERROR: Got event ${EVENT_TYPE} that cannot be handled, exiting" >&2
        exit 4
        ;;
esac
