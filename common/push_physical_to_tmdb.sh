#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Push physical release dates to TMDB via their website's Kendo grid API.
# Uses session cookies from tmdb_login.sh.
#
# Requirements:
# * sh (tested with sh from FreeBSD base FreeBSD 14.1)
# * curl (tested with 8.10.1)
# * jq (tested with 1.7.1)
# * grep, sed (POSIX)
#
# Version 0.1.0 (Released 2026-07-27)
#   * Initial implementation

. "$(dirname "$0")/scripts_common.sh"
load_config "$(dirname "$0")"

: "${DEBUG:=false}"
: "${TMDB_COOKIE_FILE:=${HOME}/.tmdb_cookies.txt}"

_COUNTRY="US"
_LANGUAGE=""
_CERTIFICATION=""
_RELEASE_TYPE=5
_NOTE=""
_DRY_RUN=false
_COOKIE_FILE="${TMDB_COOKIE_FILE}"
_RATE_LIMIT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) _DRY_RUN=true; shift ;;
        --debug) DEBUG=true; shift ;;
        --country)
            case "$2" in
                '') echo "ERROR: --country requires a code" >&2; exit 1 ;;
                *) _COUNTRY="$2"; shift 2 ;;
            esac
            ;;
        --language)
            case "$2" in
                '') echo "ERROR: --language requires a code" >&2; exit 1 ;;
                *) _LANGUAGE="$2"; shift 2 ;;
            esac
            ;;
        --certification)
            case "$2" in
                '') echo "ERROR: --certification requires a value" >&2; exit 1 ;;
                G|PG|PG-13|R|NC-17|NR) _CERTIFICATION="$2"; shift 2 ;;
                *) echo "ERROR: --certification must be one of: G, PG, PG-13, R, NC-17, NR" >&2; exit 1 ;;
            esac
            ;;
        --type)
            case "$2" in
                ''|*[!0-9]*) echo "ERROR: --type requires a number 1-7" >&2; exit 1 ;;
                *) _RELEASE_TYPE="$2"; shift 2 ;;
            esac
            ;;
        --note)
            case "$2" in
                '') echo "ERROR: --note requires text" >&2; exit 1 ;;
                *) _NOTE="$2"; shift 2 ;;
            esac
            ;;
        --cookies)
            case "$2" in
                '') echo "ERROR: --cookies requires a file path" >&2; exit 1 ;;
                *) _COOKIE_FILE="$2"; shift 2 ;;
            esac
            ;;
        --rate-limit)
            case "$2" in
                '') echo "ERROR: --rate-limit requires seconds" >&2; exit 1 ;;
                *) _RATE_LIMIT="$2"; shift 2 ;;
            esac
            ;;
        --help|-h)
            echo "Usage: $0 <tmdb_id> <date> [title]"
            echo "       $0 (reads JSON from stdin)"
            echo ""
            echo "Push physical release dates to TMDB via their website's Kendo grid API."
            echo ""
            echo "Options:"
            echo "  --dry-run           Show what would be submitted, don't POST"
            echo "  --country <code>    ISO 3166-1 country code (default: US)"
            echo "  --language <code>   ISO 639-1 language code (default: empty)"
            echo "  --certification <c> US certification: G, PG, PG-13, R, NC-17, NR (default: empty)"
            echo "  --type <N>          Release type 1-7 (default: 5)"
            echo "  --note <text>       Note field (default: empty)"
            echo "  --cookies <file>    Cookie file (default: ~/.tmdb_cookies.txt)"
            echo "  --rate-limit <s>    Seconds between requests in pipe mode (default: 1)"
            echo "  --debug             Verbose logging"
            echo "  -h, --help          Show this help"
            exit 0
            ;;
        -*) echo "ERROR: Unknown flag: $1" >&2; exit 1 ;;
        *) break ;;
    esac
done

check_needed_executables "curl jq grep sed"

if [ ! -f "${_COOKIE_FILE}" ]; then
    echo "ERROR: Cookie file not found: ${_COOKIE_FILE}" >&2
    echo "ERROR: Run tmdb_login.sh first to generate cookies." >&2
    exit 1
fi

debug_log "Cookie file: ${_COOKIE_FILE}"
debug_log "Country: ${_COUNTRY}, Language: ${_LANGUAGE}, Type: ${_RELEASE_TYPE}"

##############################################################################
# Release date submission
##############################################################################

_push_release_date() {
    local _tmdb_id _date _title _payload _response _http_code _body

    _tmdb_id="$1"
    _date="$2"
    _title="${3:-unknown}"

    _payload=$(jq -n \
        --arg country "${_COUNTRY}" \
        --arg language "${_LANGUAGE}" \
        --arg certification "${_CERTIFICATION}" \
        --arg date "${_date}" \
        --arg note "${_NOTE}" \
        --argjson type "${_RELEASE_TYPE}" \
        '{iso_3166_1: $country, iso_639_1: $language, release_date: $date, certification: $certification, type: $type, note: $note}')

    debug_log "Payload: ${_payload}"

    if [ "${_DRY_RUN}" = "true" ]; then
        echo "[${_COUNTER}/${_TOTAL}] ${_title} → TMDB #${_tmdb_id}: ${_date} (dry-run)"
        return 0
    fi

    _response=$(curl -sL -b "${_COOKIE_FILE}" \
        -H "User-Agent: Mozilla/5.0 (FreeBSD; FreeBSD 14.1; amd64) AppleWebKit/537.36" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Referer: https://www.themoviedb.org/movie/${_tmdb_id}/edit?active_nav_item=release_information" \
        -d "data=$(printf '%s' "${_payload}" | jq -sRr @uri)" \
        -w "\n%{http_code}" \
        "https://www.themoviedb.org/movie/${_tmdb_id}/remote/release_information?translate=false&timezone=UTC")

    _http_code=$(printf '%s' "${_response}" | tail -1)
    _body=$(printf '%s' "${_response}" | sed '$d')

    debug_log "HTTP ${_http_code}: ${_body}"

    if [ "${_http_code}" = "200" ] || [ "${_http_code}" = "201" ]; then
        if printf '%s' "${_body}" | jq -e '.success' >/dev/null 2>&1; then
            echo "[${_COUNTER}/${_TOTAL}] ${_title} → TMDB #${_tmdb_id}: ${_date} ✓"
            return 0
        elif printf '%s' "${_body}" | jq -e '.failure' >/dev/null 2>&1; then
            _error=$(printf '%s' "${_body}" | jq -r '.failure.errors[0] // "unknown error"')
            echo "[${_COUNTER}/${_TOTAL}] ${_title} → TMDB #${_tmdb_id}: ✗ ${_error}" >&2
            return 1
        else
            echo "[${_COUNTER}/${_TOTAL}] ${_title} → TMDB #${_tmdb_id}: ✗ Unknown response" >&2
            debug_log "Response: ${_body}"
            return 1
        fi
    elif [ "${_http_code}" = "401" ]; then
        echo "[${_COUNTER}/${_TOTAL}] ${_title} → TMDB #${_tmdb_id}: ✗ Cookies expired, re-run tmdb_login.sh" >&2
        return 1
    else
        echo "[${_COUNTER}/${_TOTAL}] ${_title} → TMDB #${_tmdb_id}: ✗ HTTP ${_http_code}" >&2
        debug_log "Response: ${_body}"
        return 1
    fi
}

##############################################################################
# Date format conversion
##############################################################################

_convert_date() {
    local _input _month _day _year _months

    _input="$1"

    # Already YYYY-MM-DD?
    if printf '%s' "${_input}" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        printf '%s' "${_input}"
        return 0
    fi

    # Try "Sep 08, 2026" or "Sep 08 2026" format
    _months="Jan:01 Feb:02 Mar:03 Apr:04 May:05 Jun:06 Jul:07 Aug:08 Sep:09 Oct:10 Nov:11 Dec:12"
    _month=$(printf '%s' "${_input}" | awk '{print $1}')
    _day=$(printf '%s' "${_input}" | awk '{print $2}' | tr -d ',')
    _day=${_day#0}
    _year=$(printf '%s' "${_input}" | awk '{print $3}')

    for _m in ${_months}; do
        _mname=$(printf '%s' "${_m}" | cut -d: -f1)
        _mnum=$(printf '%s' "${_m}" | cut -d: -f2)
        if [ "${_month}" = "${_mname}" ]; then
            printf '%s-%s-%02d' "${_year}" "${_mnum}" "${_day}"
            return 0
        fi
    done

    # Fallback: return as-is
    printf '%s' "${_input}"
}

##############################################################################
# Input handling
##############################################################################

_COUNTER=0
_TOTAL=0
_SUCCESS=0
_FAILED=0

# Args mode: single movie (check first, before pipe detection)
if [ $# -ge 2 ]; then
    _TMDB_ID="$1"
    _DATE="$2"
    _TITLE="${3:-unknown}"
    _TOTAL=1
    _COUNTER=1

    _DATE=$(_convert_date "${_DATE}")

    _push_release_date "${_TMDB_ID}" "${_DATE}" "${_TITLE}"
    exit $?
fi

# Pipe mode: read JSON from stdin
if [ ! -t 0 ]; then
    debug_log "Reading from stdin (pipe mode)"

    _TEMP=$(mktemp)
    trap 'rm -f "${_TEMP}"; exit 130' INT TERM
    trap 'rm -f "${_TEMP}"' EXIT

    cat > "${_TEMP}"

    # Handle both flat array and wrapped {results: [...]} format
    if jq -e '.results' "${_TEMP}" >/dev/null 2>&1; then
        _TOTAL=$(jq '.results | length' "${_TEMP}")
        _MOVIES_TEMP=$(mktemp)
        jq -c '.results[]' "${_TEMP}" > "${_MOVIES_TEMP}"
    else
        _TOTAL=$(jq 'length' "${_TEMP}")
        _MOVIES_TEMP=$(mktemp)
        jq -c '.[]' "${_TEMP}" > "${_MOVIES_TEMP}"
    fi
    debug_log "Processing ${_TOTAL} movies"

    _SUCCESS=0
    _FAILED=0
    _COUNTER=0

    while read -r _movie; do
        _COUNTER=$((_COUNTER + 1))
        _tmdb_id=$(printf '%s' "${_movie}" | jq -r '.tmdb_id')
        _date=$(printf '%s' "${_movie}" | jq -r '.physical_date')
        _title=$(printf '%s' "${_movie}" | jq -r '.title')

        _date=$(_convert_date "${_date}")

        if [ -z "${_tmdb_id}" ] || [ "${_tmdb_id}" = "null" ]; then
            echo "[${_COUNTER}/${_TOTAL}] ${_title}: ✗ No TMDB ID" >&2
            _FAILED=$((_FAILED + 1))
            continue
        fi

        if _push_release_date "${_tmdb_id}" "${_date}" "${_title}"; then
            _SUCCESS=$((_SUCCESS + 1))
        else
            _FAILED=$((_FAILED + 1))
        fi

        sleep "${_RATE_LIMIT}"
    done < "${_MOVIES_TEMP}"

    rm -f "${_MOVIES_TEMP}"

    rm -f "${_TEMP}"
    trap - INT TERM EXIT

    echo ""
    echo "Done: ${_SUCCESS} succeeded, ${_FAILED} failed"
    exit 0
fi

# No input
echo "Usage: $0 <tmdb_id> <date> [title]" >&2
echo "       $0 (reads JSON from stdin)" >&2
echo "" >&2
echo "Flags:" >&2
echo "  --dry-run           Show what would be submitted" >&2
echo "  --country <code>    ISO 3166-1 country (default: US)" >&2
echo "  --language <code>   ISO 639-1 language (default: empty)" >&2
echo "  --certification <c> US certification: G, PG, PG-13, R, NC-17, NR (default: empty)" >&2
echo "  --type <N>          Release type 1-7 (default: 5)" >&2
echo "  --note <text>       Note field (default: empty)" >&2
echo "  --cookies <file>    Cookie file (default: ~/.tmdb_cookies.txt)" >&2
echo "  --debug             Verbose logging" >&2
exit 1
