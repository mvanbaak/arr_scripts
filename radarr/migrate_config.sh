#!/usr/bin/env sh
# Version 1.0.0 (Released 2026-09-11)
#
# Migrates radarr/connect/scripts.conf to the new layout.
# Run once after updating to the directory-restructured branch.

set -e

_old="radarr/connect/scripts.conf"
_new="radarr/scripts.conf"

if [ ! -f "${_old}" ]
then
    echo "Nothing to migrate — '${_old}' not found." >&2
    exit 0
fi

if [ -f "${_new}" ]
then
    echo "Already migrated — '${_new}' exists." >&2
    exit 0
fi

cp "${_old}" "${_new}"
echo "Migrated: ${_old} -> ${_new}" >&2
echo "" >&2
echo "Optional: move shared vars (TMDB_API_KEY, YT_DLP_*," >&2
echo "AUTOPULSE_*) to common/scripts.conf for cross-app sharing." >&2
