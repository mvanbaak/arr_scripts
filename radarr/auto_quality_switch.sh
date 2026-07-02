#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Script to automatically switch movies from a Remux-only quality profile
# to a WebDL-enabled profile when no physical release appears within a
# statistically determined threshold (P95 of the web->physical gap).
#
# Requirements:
# * sh (tested with sh from FreeBSD base FreeBSD 14.1)
# * curl (tested with 8.10.1)
# * jq (tested with 1.7.1)
#
# Version 0.1.0 (Released 2026-07-02)
#   * Initial implementation

# Load shared library and configuration
. "$(dirname "$0")/connect/scripts_common.sh"
load_config "$(dirname "$0")/connect"

# Script-specific defaults
: "${SOURCE_PROFILE_NAME:=Remux-2160p}"
: "${TARGET_PROFILE_NAME:=WebDL-2160p}"
: "${P_VALUE:=0.95}"
: "${MIN_SAMPLE:=30}"
: "${FALLBACK_THRESHOLD:=365}"
: "${MIN_THRESHOLD:=90}"
: "${MAX_THRESHOLD:=730}"
: "${DRY_RUN:=true}"
: "${MAX_SWITCH_PER_RUN:=0}"
: "${TRIGGER_SEARCH:=true}"
: "${DEBUG:=false}"

# CLI flags
_FLAG_APPLY=false
_FLAG_JSON=false
_FLAG_QUIET=false
_DEFER_JSON=false

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) _FLAG_APPLY=true; shift ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -j|--json) _FLAG_JSON=true; shift ;;
        -q|--quiet) _FLAG_QUIET=true; shift ;;
        -d|--debug) DEBUG=true; shift ;;
        *) break ;;
    esac
done

check_needed_executables "curl jq"

debug_log "=== Auto Quality Profile Switch ==="
debug_log "Source profile: ${SOURCE_PROFILE_NAME}"
debug_log "Target profile: ${TARGET_PROFILE_NAME}"
debug_log "P_VALUE: ${P_VALUE}"

# --apply flag overrides DRY_RUN config
if [ "${_FLAG_APPLY}" = "true" ]
then
    DRY_RUN=false
fi

# --json takes precedence over --quiet
if [ "${_FLAG_JSON}" = "true" ]
then
    _FLAG_QUIET=false
fi

##############################################################################
# Phase 2: Profile resolution
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

debug_log "Resolving source profile ID"
SOURCE_PROFILE_ID=$(_resolve_profile_id "${SOURCE_PROFILE_NAME}")
_resolve_rc=$?
if [ "${_resolve_rc}" -ne 0 ]
then
    exit 1
fi
debug_log "Source profile: ${SOURCE_PROFILE_NAME} (id: ${SOURCE_PROFILE_ID})"

debug_log "Resolving target profile ID"
TARGET_PROFILE_ID=$(_resolve_profile_id "${TARGET_PROFILE_NAME}")
_resolve_rc=$?
if [ "${_resolve_rc}" -ne 0 ]
then
    exit 1
fi
debug_log "Target profile: ${TARGET_PROFILE_NAME} (id: ${TARGET_PROFILE_ID})"

if [ "${SOURCE_PROFILE_ID}" = "${TARGET_PROFILE_ID}" ]
then
    echo "ERROR: Source and target profiles are the same (id: ${SOURCE_PROFILE_ID})" >&2
    echo "ERROR: Nothing to switch. Exiting." >&2
    exit 1
fi

##############################################################################
# Phase 3: Threshold computation
##############################################################################

debug_log "Fetching all movies from Radarr API"
_ALL_MOVIES=$(radarr_api_get "movie")

if [ -z "${_ALL_MOVIES}" ]
then
    echo "ERROR: No response from movie API" >&2
    exit 1
fi

_THRESHOLD_JSON=$(printf '%s' "${_ALL_MOVIES}" | jq \
    --arg p_value "${P_VALUE}" \
    --arg min_sample "${MIN_SAMPLE}" \
    '
def iqr_filter:
    if length == 0 then []
    else
        sort as $sorted
        | (($sorted | length) * 0.25 | floor) as $q1_idx
        | (($sorted | length) * 0.75 | floor) as $q3_idx
        | $sorted[$q1_idx] as $q1
        | $sorted[$q3_idx] as $q3
        | ($q3 - $q1) as $iqr
        | ($q1 - 1.5 * $iqr) as $lower
        | ($q3 + 1.5 * $iqr) as $upper
        | [.[] | select(. >= $lower and . <= $upper)]
    end;

[.[] | select(.digitalRelease != null and .physicalRelease != null)
 | ((.physicalRelease | fromdateiso8601) - (.digitalRelease | fromdateiso8601)) / 86400] as $gaps

| if ($gaps | length) < ($min_sample | tonumber) then
    {threshold: null, sample_size: ($gaps | length), used_fallback: true}
else
    ($gaps | iqr_filter | sort) as $filtered
    | ($filtered[(($filtered | length) * ($p_value | tonumber)) | floor]) as $p_val
    | {threshold: $p_val, sample_size: ($gaps | length), filtered_size: ($filtered | length), used_fallback: false}
end
')

_THRESHOLD=$(printf '%s' "${_THRESHOLD_JSON}" | jq -r '.threshold')
_SAMPLE_SIZE=$(printf '%s' "${_THRESHOLD_JSON}" | jq -r '.sample_size')
_USED_FALLBACK=$(printf '%s' "${_THRESHOLD_JSON}" | jq -r '.used_fallback')

if [ "${_USED_FALLBACK}" = "true" ] || [ -z "${_THRESHOLD}" ] || [ "${_THRESHOLD}" = "null" ]
then
    _THRESHOLD="${FALLBACK_THRESHOLD}"
    debug_log "Using fallback threshold: ${_THRESHOLD}d (sample size: ${_SAMPLE_SIZE})"
fi

# Clamp to [MIN_THRESHOLD, MAX_THRESHOLD]
if [ "${_THRESHOLD}" -lt "${MIN_THRESHOLD}" ] 2>/dev/null
then
    _THRESHOLD="${MIN_THRESHOLD}"
    debug_log "Threshold clamped to MIN_THRESHOLD: ${_THRESHOLD}d"
fi

if [ "${_THRESHOLD}" -gt "${MAX_THRESHOLD}" ] 2>/dev/null
then
    _THRESHOLD="${MAX_THRESHOLD}"
    debug_log "Threshold clamped to MAX_THRESHOLD: ${_THRESHOLD}d"
fi

##############################################################################
# Phase 4: Candidate matching
##############################################################################

_CANDIDATES=$(printf '%s' "${_ALL_MOVIES}" | jq \
    --arg threshold "${_THRESHOLD}" \
    --arg source_id "${SOURCE_PROFILE_ID}" \
    '
[.[] | select(
    .digitalRelease != null
    and .physicalRelease == null
    and .qualityProfileId == ($source_id | tonumber)
    and .inCinemas != null
    and .hasFile == false
    and .monitored == true
) | ((.digitalRelease | fromdateiso8601)) as $web_epoch
  | ((now - $web_epoch) / 86400) as $waiting_days
  | select($waiting_days >= ($threshold | tonumber))
  | {id: .id, title: .title, year: .year, waiting_days: $waiting_days, qualityProfileId: .qualityProfileId}]
| sort_by(.waiting_days) | reverse
')

_CANDIDATE_COUNT=$(printf '%s' "${_CANDIDATES}" | jq 'length')

# Unset to free memory
unset _ALL_MOVIES

debug_log "Threshold: P${P_VALUE} = ${_THRESHOLD}d (based on ${_SAMPLE_SIZE} movies with both dates)"
debug_log "Candidates: ${_CANDIDATE_COUNT} movies"

##############################################################################
# Phase 7: Output (table or JSON)
##############################################################################

if [ "${_FLAG_JSON}" = "true" ]
then
    _DEFER_JSON=false

    if [ "${DRY_RUN}" = "true" ] || [ "${_CANDIDATE_COUNT}" -eq 0 ]
    then
        # Dry-run or no candidates: output JSON immediately and exit
        _SWITCHED_COUNT=0

        printf '%s' "${_CANDIDATES}" | jq \
            --arg threshold "${_THRESHOLD}" \
            --arg p_value "${P_VALUE}" \
            --arg sample_size "${_SAMPLE_SIZE}" \
            --arg src_name "${SOURCE_PROFILE_NAME}" \
            --arg src_id "${SOURCE_PROFILE_ID}" \
            --arg tgt_name "${TARGET_PROFILE_NAME}" \
            --arg tgt_id "${TARGET_PROFILE_ID}" \
            --arg switched_count "${_SWITCHED_COUNT}" \
            --arg searched_count "0" \
            --arg search_triggered "false" \
            --argjson dry_run "${DRY_RUN}" \
            '
{
    threshold_days: ($threshold | tonumber),
    p_value: ($p_value | tonumber),
    sample_size: ($sample_size | tonumber),
    source_profile: {id: ($src_id | tonumber), name: $src_name},
    target_profile: {id: ($tgt_id | tonumber), name: $tgt_name},
    candidates: .,
    candidate_count: length,
    switched_count: ($switched_count | tonumber),
    searched_count: ($searched_count | tonumber),
    search_triggered: ($search_triggered == "true"),
    dry_run: $dry_run
}
'
        echo
        exit 0
    fi

    # Apply + JSON mode: defer JSON output until after switch
    _DEFER_JSON=true
fi

# Print pretty table (only in non-JSON mode)
if [ "${_FLAG_JSON}" = "false" ]
then
    if [ "${_FLAG_QUIET}" = "false" ]
    then
        echo
        echo "Auto Quality Profile Switch"
        echo "==========================="
        echo
        echo "Threshold: P${P_VALUE} = ${_THRESHOLD}d (based on ${_SAMPLE_SIZE} movies with both dates)"
        echo "Source profile: ${SOURCE_PROFILE_NAME} (id: ${SOURCE_PROFILE_ID})"
        echo "Target profile: ${TARGET_PROFILE_NAME} (id: ${TARGET_PROFILE_ID})"
        echo
    fi

    if [ "${_CANDIDATE_COUNT}" -gt 0 ] && [ "${_FLAG_QUIET}" = "false" ]
    then
        printf '%-50s %8s %-20s  %s\n' "Movie" "Waiting" "Current Profile" "-> Target"
        printf '%-50s %8s %-20s  %s\n' "-----" "-------" "---------------" "--------"

        printf '%s' "${_CANDIDATES}" | jq -r '.[] | "\(.title) (\(.year))|\(.waiting_days)|\(.qualityProfileId)"' | \
        while IFS='|' read -r _title _waiting _profile_id; do
            printf '%-50s %6dd  %-20s  -> %s\n' "${_title}" "${_waiting%.*}" "${SOURCE_PROFILE_NAME}" "${TARGET_PROFILE_NAME}"
        done
        echo
    fi

    if [ "${_FLAG_QUIET}" = "false" ]
    then
        if [ "${_CANDIDATE_COUNT}" -eq 0 ]
        then
            echo "No candidates to switch."
            echo
            exit 0
        fi

        if [ "${DRY_RUN}" = "true" ]
        then
            echo "DRY-RUN: ${_CANDIDATE_COUNT} movies would switch. Run with --apply to execute."
            echo
            exit 0
        fi
    fi
fi

##############################################################################
# Phase 5: Switch execution
##############################################################################

_SWITCHED_COUNT=0
_SWITCHED_IDS=""

_SWITCH_TEMP=$(mktemp)
# shellcheck disable=SC2064
trap 'rm -f "${_SWITCH_TEMP}"; exit 130' INT TERM
trap 'rm -f "${_SWITCH_TEMP}"' EXIT

printf '%s' "${_CANDIDATES}" | jq -r '.[].id' > "${_SWITCH_TEMP}"

while read -r _movie_id
do
    if [ "${MAX_SWITCH_PER_RUN}" -gt 0 ] && [ "${_SWITCHED_COUNT}" -ge "${MAX_SWITCH_PER_RUN}" ]
    then
        debug_log "MAX_SWITCH_PER_RUN (${MAX_SWITCH_PER_RUN}) reached, stopping"
        break
    fi

    _payload=$(printf '{"movieIds": [%s], "qualityProfileId": %s}' "${_movie_id}" "${TARGET_PROFILE_ID}")

    debug_log "Switching movie ${_movie_id} to profile ${TARGET_PROFILE_ID}"

    _response=$(curl \
        -s \
        -X PUT \
        -H "Accept-Encoding: application/json" \
        -H "X-Api-Key: ${RADARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "${_payload}" \
        "${RADARR_API_URL}/movie/editor" \
        -w "\n%{http_code}")

    _http_code=$(printf '%s' "${_response}" | tail -1)
    _body=$(printf '%s' "${_response}" | sed '$d')

    case "${_http_code}" in
        2*)
            _SWITCHED_COUNT=$((_SWITCHED_COUNT + 1))
            if [ -z "${_SWITCHED_IDS}" ]
            then
                _SWITCHED_IDS="${_movie_id}"
            else
                _SWITCHED_IDS="${_SWITCHED_IDS},${_movie_id}"
            fi
            debug_log "  OK (HTTP ${_http_code})"
            ;;
        *)
            echo "WARN: Failed to switch movie ${_movie_id} (HTTP ${_http_code}): ${_body}" >&2
            ;;
    esac

    sleep 0.5
done < "${_SWITCH_TEMP}"

rm -f "${_SWITCH_TEMP}"
trap - INT TERM EXIT

##############################################################################
# Phase 6: Search trigger
##############################################################################

_SEARCH_QUEUED=0

if [ "${TRIGGER_SEARCH}" = "true" ] && [ "${_SWITCHED_COUNT}" -gt 0 ]
then
    debug_log "Triggering search for ${_SWITCHED_COUNT} switched movies"

    _ids_json=$(printf '%s' "${_SWITCHED_IDS}" | jq -R 'split(",") | map(tonumber)')

    _search_response=$(curl \
        -s \
        -X POST \
        -H "Accept-Encoding: application/json" \
        -H "X-Api-Key: ${RADARR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"MoviesSearch\", \"movieIds\": ${_ids_json}}" \
        "${RADARR_API_URL}/command" \
        -w "\n%{http_code}")

    _search_http=$(printf '%s' "${_search_response}" | tail -1)
    _search_body=$(printf '%s' "${_search_response}" | sed '$d')

    case "${_search_http}" in
        2*)
            _SEARCH_QUEUED="${_SWITCHED_COUNT}"
            debug_log "Search command queued (HTTP ${_search_http}, jobId: $(printf '%s' "${_search_body}" | jq -r '.jobId // "unknown"'))"
            ;;
        *)
            echo "WARN: Search command failed (HTTP ${_search_http}): ${_search_body}" >&2
            echo "WARN: Movies are switched but not searched. Next Radarr search pass will pick them up." >&2
            ;;
    esac
fi

##############################################################################
# Final summary
##############################################################################

if [ "${_DEFER_JSON}" = "true" ]
then
    # JSON output with real switched_count and searched_count
    printf '%s' "${_CANDIDATES}" | jq \
        --arg threshold "${_THRESHOLD}" \
        --arg p_value "${P_VALUE}" \
        --arg sample_size "${_SAMPLE_SIZE}" \
        --arg src_name "${SOURCE_PROFILE_NAME}" \
        --arg src_id "${SOURCE_PROFILE_ID}" \
        --arg tgt_name "${TARGET_PROFILE_NAME}" \
        --arg tgt_id "${TARGET_PROFILE_ID}" \
        --arg switched_count "${_SWITCHED_COUNT}" \
        --arg searched_count "${_SEARCH_QUEUED}" \
        --argjson dry_run false \
        '
{
    threshold_days: ($threshold | tonumber),
    p_value: ($p_value | tonumber),
    sample_size: ($sample_size | tonumber),
    source_profile: {id: ($src_id | tonumber), name: $src_name},
    target_profile: {id: ($tgt_id | tonumber), name: $tgt_name},
    candidates: .,
    candidate_count: length,
    switched_count: ($switched_count | tonumber),
    searched_count: ($searched_count | tonumber),
    search_triggered: (($searched_count | tonumber) > 0),
    dry_run: false
}
'
    echo
elif [ "${_FLAG_QUIET}" = "false" ]
then
    echo "APPLY: Switched ${_SWITCHED_COUNT} movies to ${TARGET_PROFILE_NAME}"
    if [ "${_SEARCH_QUEUED}" -gt 0 ]
    then
        echo "QUEUED: ${_SEARCH_QUEUED} movies sent for search"
    elif [ "${TRIGGER_SEARCH}" = "true" ] && [ "${_SWITCHED_COUNT}" -gt 0 ]
    then
        echo "WARN: Search was not queued (see warnings above)"
    elif [ "${TRIGGER_SEARCH}" = "false" ]
    then
        echo "Search skipped (TRIGGER_SEARCH=false)"
    fi
    echo
fi

exit 0
