#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Script to switch movies back to a Remux-only quality profile when
# physical release dates appear for movies previously switched to WebDL.
# Uses Radarr tags to identify movies switched by the forward script.
#
# Requirements:
# * sh (tested with sh from FreeBSD base FreeBSD 14.1)
# * curl (tested with 8.10.1)
# * jq (tested with 1.7.1)
#
# Version 0.2.0 (Released 2026-07-18)
#   * Use SOURCE_PROFILE_NAME and TARGET_PROFILE_NAME from config
#     instead of duplicate SWITCH_TO/FROM_PROFILE_NAME
#
# Version 0.1.0 (Released 2026-07-14)
#   * Initial implementation

# Load shared library and configuration
. "$(dirname "$0")/connect/scripts_common.sh"
load_config "$(dirname "$0")/connect"

# Script-specific defaults
: "${SOURCE_PROFILE_NAME:=Remux-2160p}"
: "${TARGET_PROFILE_NAME:=WebDL-2160p}"
: "${AUTO_SWITCH_TAG:=auto-switched}"
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

debug_log "=== Auto Quality Profile Switch (Reverse) ==="
debug_log "Switch to profile: ${SOURCE_PROFILE_NAME}"
debug_log "Switch from profile: ${TARGET_PROFILE_NAME}"

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
# Phase 1: Profile resolution
##############################################################################

debug_log "Resolving switch-to profile ID"
SOURCE_PROFILE_ID=$(_resolve_profile_id "${SOURCE_PROFILE_NAME}")
_resolve_rc=$?
if [ "${_resolve_rc}" -ne 0 ]
then
    exit 1
fi
debug_log "Switch-to profile: ${SOURCE_PROFILE_NAME} (id: ${SOURCE_PROFILE_ID})"

debug_log "Resolving switch-from profile ID"
TARGET_PROFILE_ID=$(_resolve_profile_id "${TARGET_PROFILE_NAME}")
_resolve_rc=$?
if [ "${_resolve_rc}" -ne 0 ]
then
    exit 1
fi
debug_log "Switch-from profile: ${TARGET_PROFILE_NAME} (id: ${TARGET_PROFILE_ID})"

if [ "${SOURCE_PROFILE_ID}" = "${TARGET_PROFILE_ID}" ]
then
    echo "ERROR: Switch-to and switch-from profiles are the same (id: ${SOURCE_PROFILE_ID})" >&2
    echo "ERROR: Nothing to switch. Exiting." >&2
    exit 1
fi

##############################################################################
# Phase 2: Tag resolution
##############################################################################

debug_log "Resolving auto-switch tag"
AUTO_SWITCH_TAG_ID=$(get_tag_id_by_label "${AUTO_SWITCH_TAG}")

if [ -z "${AUTO_SWITCH_TAG_ID}" ]
then
    debug_log "Tag '${AUTO_SWITCH_TAG}' not found, creating"
    AUTO_SWITCH_TAG_ID=$(create_tag "${AUTO_SWITCH_TAG}")
    if [ -z "${AUTO_SWITCH_TAG_ID}" ] || [ "${AUTO_SWITCH_TAG_ID}" = "null" ]
    then
        echo "ERROR: Failed to create tag '${AUTO_SWITCH_TAG}'" >&2
        exit 1
    fi
    _TAG_CACHE=""
fi

debug_log "Tag '${AUTO_SWITCH_TAG}' (id: ${AUTO_SWITCH_TAG_ID})"

##############################################################################
# Phase 3: Candidate matching
##############################################################################

debug_log "Fetching all movies from Radarr API"
_ALL_MOVIES=$(radarr_api_get "movie")

if [ -z "${_ALL_MOVIES}" ]
then
    echo "ERROR: No response from movie API" >&2
    exit 1
fi

_CANDIDATES=$(printf '%s' "${_ALL_MOVIES}" | jq \
    --arg tag_id "${AUTO_SWITCH_TAG_ID}" \
    --arg from_profile_id "${TARGET_PROFILE_ID}" \
    '
[.[] | select(
    (.tags | index(($tag_id | tonumber)))
    and .physicalRelease != null
    and .qualityProfileId == ($from_profile_id | tonumber)
) | {id: .id, title: .title, year: .year, physicalRelease: .physicalRelease, qualityProfileId: .qualityProfileId}]
')

_CANDIDATE_COUNT=$(printf '%s' "${_CANDIDATES}" | jq 'length')

# Unset to free memory
unset _ALL_MOVIES

debug_log "Candidates: ${_CANDIDATE_COUNT} movies"

##############################################################################
# Phase 6: Output (table or JSON)
##############################################################################

if [ "${_FLAG_JSON}" = "true" ]
then
    _DEFER_JSON=false

    if [ "${DRY_RUN}" = "true" ] || [ "${_CANDIDATE_COUNT}" -eq 0 ]
    then
        # Dry-run or no candidates: output JSON immediately and exit
        _SWITCHED_COUNT=0

        printf '%s' "${_CANDIDATES}" | jq \
            --arg switch_to_name "${SOURCE_PROFILE_NAME}" \
            --arg switch_to_id "${SOURCE_PROFILE_ID}" \
            --arg switch_from_name "${TARGET_PROFILE_NAME}" \
            --arg switch_from_id "${TARGET_PROFILE_ID}" \
            --arg tag_label "${AUTO_SWITCH_TAG}" \
            --arg tag_id "${AUTO_SWITCH_TAG_ID}" \
            --arg switched_count "${_SWITCHED_COUNT}" \
            --arg searched_count "0" \
            --arg search_triggered "false" \
            --argjson dry_run "${DRY_RUN}" \
            '
{
    switch_to_profile: {id: ($switch_to_id | tonumber), name: $switch_to_name},
    switch_from_profile: {id: ($switch_from_id | tonumber), name: $switch_from_name},
    tag: {id: ($tag_id | tonumber), label: $tag_label},
    candidates: .,
    candidate_count: length,
    switched_count: ($switched_count | tonumber),
    tags_removed: ($switched_count | tonumber),
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
        echo "Auto Quality Profile Switch (Reverse)"
        echo "====================================="
        echo
        echo "Source profile: ${TARGET_PROFILE_NAME} (id: ${TARGET_PROFILE_ID})"
        echo "Target profile: ${SOURCE_PROFILE_NAME} (id: ${SOURCE_PROFILE_ID})"
        echo "Tag: ${AUTO_SWITCH_TAG} (id: ${AUTO_SWITCH_TAG_ID})"
        echo
    fi

    if [ "${_CANDIDATE_COUNT}" -gt 0 ] && [ "${_FLAG_QUIET}" = "false" ]
    then
        printf '%-50s %-12s %-20s  %s\n' "Movie" "Phys Release" "Current Profile" "-> Target"
        printf '%-50s %-12s %-20s  %s\n' "-----" "------------" "---------------" "--------"

        printf '%s' "${_CANDIDATES}" | jq -r '.[] | "\(.title) (\(.year))|\(.physicalRelease[:10])|\(.qualityProfileId)"' | \
        while IFS='|' read -r _title _phys_release _profile_id; do
            printf '%-50s %-12s %-20s  -> %s\n' "${_title}" "${_phys_release}" "${TARGET_PROFILE_NAME}" "${SOURCE_PROFILE_NAME}"
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
# Phase 4: Switch execution
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

    _payload=$(printf '{"movieIds": [%s], "qualityProfileId": %s}' "${_movie_id}" "${SOURCE_PROFILE_ID}")

    debug_log "Switching movie ${_movie_id} to profile ${SOURCE_PROFILE_ID}"

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
            debug_log "  Switched (HTTP ${_http_code})"

            # Remove auto-switch tag
            if remove_tag_from_movie "${_movie_id}" "${AUTO_SWITCH_TAG}"
            then
                debug_log "  Untagged '${AUTO_SWITCH_TAG}'"
            else
                echo "WARN: Failed to remove tag from movie ${_movie_id}" >&2
            fi
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
# Phase 5: Search trigger
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
        --arg switch_to_name "${SOURCE_PROFILE_NAME}" \
        --arg switch_to_id "${SOURCE_PROFILE_ID}" \
        --arg switch_from_name "${TARGET_PROFILE_NAME}" \
        --arg switch_from_id "${TARGET_PROFILE_ID}" \
        --arg tag_label "${AUTO_SWITCH_TAG}" \
        --arg tag_id "${AUTO_SWITCH_TAG_ID}" \
        --arg switched_count "${_SWITCHED_COUNT}" \
        --arg searched_count "${_SEARCH_QUEUED}" \
        --argjson dry_run false \
        '
{
    switch_to_profile: {id: ($switch_to_id | tonumber), name: $switch_to_name},
    switch_from_profile: {id: ($switch_from_id | tonumber), name: $switch_from_name},
    tag: {id: ($tag_id | tonumber), label: $tag_label},
    candidates: .,
    candidate_count: length,
    switched_count: ($switched_count | tonumber),
    tags_removed: ($switched_count | tonumber),
    searched_count: ($searched_count | tonumber),
    search_triggered: (($searched_count | tonumber) > 0),
    dry_run: false
}
'
    echo
elif [ "${_FLAG_QUIET}" = "false" ]
then
    echo "APPLY: Switched ${_SWITCHED_COUNT} movies to ${SOURCE_PROFILE_NAME}"
    echo "TAGS: Removed auto-switched tag from ${_SWITCHED_COUNT} movies"
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
