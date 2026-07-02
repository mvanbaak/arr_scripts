#!/usr/bin/env sh
# Dont warn on the word `local`
# shellcheck disable=SC3043

# Script to compute release date statistics from Radarr.
# Analyzes cinema, digital, and physical release dates across all movies.
#
# Requirements:
# * sh (tested with sh from FreeBSD base FreeBSD 14.1)
# * curl (tested with 8.10.1)
# * jq (tested with 1.7.1)
#
# Version 0.3.0 (Released 2026-07-02)
#   * Add percentiles (P50/P90/P95/P99) to web->physical gap
#   * Cinema+Web category shows waiting time distribution
#   * Add threshold-based counts for profile switch planning
#   * Decision-oriented output focused on profile policy
#
# Version 0.2.0 (Released 2026-07-02)
#   * Add IQR-based outlier filtering for clean stats
#   * Show raw + filtered side by side in output
#
# Version 0.1.0 (Released 2026-07-02)
#   * Initial implementation
#     * Fetch all movies from Radarr API
#     * Compute web-to-physical gap stats (min/max/avg)
#     * Count movies in 3 date-availability categories
#     * Compute cinema-to-web and cinema-to-physical gaps per category
#     * Pretty table + JSON output

# Load shared library and configuration
. "$(dirname "$0")/../connect/scripts_common.sh"
load_config "$(dirname "$0")/../connect"

: "${OUTPUT_JSON:=false}"
: "${DEBUG:=false}"
: "${PRETTY_JSON:=false}"

# Parse optional flags
while [ $# -gt 0 ]; do
    case "$1" in
        -j|--json) OUTPUT_JSON=true; shift ;;
        -p|--pretty) PRETTY_JSON=true; shift ;;
        -d|--debug) DEBUG=true; shift ;;
        *) break ;;
    esac
done

check_needed_executables "curl jq"

debug_log "Fetching all movies from Radarr API"
_all_movies=$(radarr_api_get "movie")

if [ -z "${_all_movies}" ]
then
    echo "ERROR: No response from Radarr API" >&2
    exit 1
fi

_computed_stats=$(printf '%s' "${_all_movies}" | jq '
def percentiles:
    if length == 0 then null
    else
        sort as $sorted
        | {p50: $sorted[(length * 0.5) | floor],
           p90: $sorted[(length * 0.9) | floor],
           p95: $sorted[(length * 0.95) | floor],
           p99: $sorted[(length * 0.99) | floor]}
    end;

def iqr_filtered_stats:
    if length == 0 then
        {count: 0, raw: null, filtered: null}
    else
        sort as $sorted
        | (($sorted | length) * 0.25 | floor) as $q1_idx
        | (($sorted | length) * 0.75 | floor) as $q3_idx
        | $sorted[$q1_idx] as $q1
        | $sorted[$q3_idx] as $q3
        | ($q3 - $q1) as $iqr
        | ($q1 - 1.5 * $iqr) as $lower
        | ($q3 + 1.5 * $iqr) as $upper
        | [.[] | select(. >= $lower and . <= $upper)] as $filtered
        | {count: length,
           raw: {min_days: min, max_days: max, avg_days: (add / length)},
           filtered: (if ($filtered | length) > 0 then
               {min_days: ($filtered | min), max_days: ($filtered | max), avg_days: (($filtered | add) / ($filtered | length)), outliers_removed: (length - ($filtered | length)),
                percentiles: ($filtered | percentiles)}
             else
               {min_days: null, max_days: null, avg_days: null, outliers_removed: length,
                percentiles: null}
             end)}
    end;

map(select(.inCinemas != null))
| {
    "total_movies_with_cinema_date": length,
    "web_to_physical": (
        [.[] | select(.digitalRelease != null and .physicalRelease != null)
         | ((.physicalRelease | fromdateiso8601) - (.digitalRelease | fromdateiso8601)) / 86400]
        | iqr_filtered_stats
    ),
    "cinema_only": (
        [.[] | select(.digitalRelease == null and .physicalRelease == null)]
        | {count: length}
    ),
    "cinema_web": (
        [.[] | select(.digitalRelease != null and .physicalRelease == null)
         | ((.digitalRelease | fromdateiso8601)) as $web_epoch
         | ((now - $web_epoch) / 86400)] as $waiting_times
        | ($waiting_times | sort) as $sorted
        | if ($waiting_times | length) > 0 then
            {count: ($waiting_times | length),
             waiting_days_p50: $sorted[($sorted | length * 0.5) | floor],
             waiting_days_p90: $sorted[($sorted | length * 0.9) | floor],
             waiting_days_p95: $sorted[($sorted | length * 0.95) | floor],
             waiting_days_max: $sorted[-1],
             thresholds: {
                 gt_90:  ([$waiting_times[] | select(. > 90)] | length),
                 gt_180: ([$waiting_times[] | select(. > 180)] | length),
                 gt_365: ([$waiting_times[] | select(. > 365)] | length),
                 gt_730: ([$waiting_times[] | select(. > 730)] | length)
             }}
          else
            {count: 0}
          end
    ),
    "cinema_physical": (
        [.[] | select(.digitalRelease == null and .physicalRelease != null)
         | ((.physicalRelease | fromdateiso8601) - (.inCinemas | fromdateiso8601)) / 86400]
        | iqr_filtered_stats
    )
}
')

if [ -z "${_computed_stats}" ]
then
    echo "ERROR: Failed to compute statistics" >&2
    exit 1
fi

if [ "${OUTPUT_JSON}" = "true" ]
then
    if [ "${PRETTY_JSON}" = "true" ]
    then
        printf '%s' "${_computed_stats}" | jq '.'
    else
        printf '%s' "${_computed_stats}"
    fi
    echo
    exit 0
fi

# Extract stats
_web_count=$(printf '%s' "${_computed_stats}" | jq '.web_to_physical.count')
_web_outliers=$(printf '%s' "${_computed_stats}" | jq -r '.web_to_physical.filtered.outliers_removed // 0')
_web_p50=$(printf '%s' "${_computed_stats}" | jq -r '.web_to_physical.filtered.percentiles.p50 // "N/A"')
_web_p90=$(printf '%s' "${_computed_stats}" | jq -r '.web_to_physical.filtered.percentiles.p90 // "N/A"')
_web_p95=$(printf '%s' "${_computed_stats}" | jq -r '.web_to_physical.filtered.percentiles.p95 // "N/A"')
_web_p99=$(printf '%s' "${_computed_stats}" | jq -r '.web_to_physical.filtered.percentiles.p99 // "N/A"')

_cat_a=$(printf '%s' "${_computed_stats}" | jq '.cinema_only.count')

_cat_b_count=$(printf '%s' "${_computed_stats}" | jq '.cinema_web.count')
_cat_b_wait_p50=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_web.waiting_days_p50 // "N/A"')
_cat_b_wait_p90=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_web.waiting_days_p90 // "N/A"')
_cat_b_wait_p95=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_web.waiting_days_p95 // "N/A"')
_cat_b_wait_max=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_web.waiting_days_max // "N/A"')
_cat_b_gt_90=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_web.thresholds.gt_90 // 0')
_cat_b_gt_180=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_web.thresholds.gt_180 // 0')
_cat_b_gt_365=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_web.thresholds.gt_365 // 0')
_cat_b_gt_730=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_web.thresholds.gt_730 // 0')

_cat_c_count=$(printf '%s' "${_computed_stats}" | jq '.cinema_physical.count')
_cat_c_raw_min=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_physical.raw.min_days // "N/A"')
_cat_c_raw_max=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_physical.raw.max_days // "N/A"')
_cat_c_raw_avg=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_physical.raw.avg_days // "N/A"')
_cat_c_filt_min=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_physical.filtered.min_days // "N/A"')
_cat_c_filt_max=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_physical.filtered.max_days // "N/A"')
_cat_c_filt_avg=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_physical.filtered.avg_days // "N/A"')
_cat_c_filt_removed=$(printf '%s' "${_computed_stats}" | jq -r '.cinema_physical.filtered.outliers_removed // 0')

_total=$(printf '%s' "${_computed_stats}" | jq '.total_movies_with_cinema_date')

echo
echo "Release Date Analysis for Profile Decision"
echo "==========================================="
echo
echo "Movies with cinema date: ${_total}"

echo
echo "=== Web -> Physical Gap ==="
echo "Movies with both dates: ${_web_count}"
echo "(IQR filtering removed ${_web_outliers} outliers)"
echo
echo "Days from web release to physical release:"
echo "  P50 (median):  ${_web_p50}d  - half of physical releases within this"
echo "  P90:           ${_web_p90}d  - 90% within this"
echo "  P95:           ${_web_p95}d  - 95% within this"
echo "  P99:           ${_web_p99}d  - 99% within this"

echo
echo "=== Cinema + Web, No Physical ==="
echo "Movies: ${_cat_b_count}"
echo
echo "How long they have been waiting for a physical:"
if [ "${_cat_b_count}" -gt 0 ] 2>/dev/null
then
    echo "  P50 waiting:    ${_cat_b_wait_p50}d"
    echo "  P90 waiting:    ${_cat_b_wait_p90}d"
    echo "  P95 waiting:    ${_cat_b_wait_p95}d"
    echo
    echo "Would switch profile at threshold:"
    echo "  >  90d:  ${_cat_b_gt_90} movies"
    echo "  > 180d:  ${_cat_b_gt_180} movies"
    echo "  > 365d:  ${_cat_b_gt_365} movies"
    echo "  > 730d:  ${_cat_b_gt_730} movies"
fi

echo
echo "=== Cinema only (no web, no physical) ==="
echo "Movies: ${_cat_a}"

echo
echo "=== Cinema + Physical, No Web ==="
echo "Movies: ${_cat_c_count}"
if [ "${_cat_c_count}" -gt 0 ] 2>/dev/null
then
    echo "  Raw:       min ${_cat_c_raw_min}d  max ${_cat_c_raw_max}d  avg ${_cat_c_raw_avg}d"
    echo "  Filtered:  min ${_cat_c_filt_min}d  max ${_cat_c_filt_max}d  avg ${_cat_c_filt_avg}d  (${_cat_c_filt_removed} outliers removed)"
fi

echo
echo "--- JSON ---"
printf '%s' "${_computed_stats}" | jq '.'
