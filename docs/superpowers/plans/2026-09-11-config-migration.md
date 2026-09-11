# Config Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add backward-compatible migration path for users with config at old `radarr/connect/scripts.conf`.

**Architecture:** `load_config()` checks old path as fallback when no new config found, prints deprecation warning. Separate migration script automates the `cp`. README gets migration section.

**Tech Stack:** POSIX sh, shellcheck

---

### Task 1: Migration fallback in `load_config()`

**Files:**
- Modify: `common/scripts_common.sh` (lines 22-35, inside `load_config()`)

- [ ] **Step 1: Add migration fallback to `load_config()`**

Replace the current `load_config()` body with:

```sh
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
}
```

- [ ] **Step 2: Verify**

```bash
sh -n common/scripts_common.sh
shellcheck -e SC1091,SC3043,SC1090 common/scripts_common.sh
```
Both must exit 0.

- [ ] **Step 3: Commit**

```bash
git add common/scripts_common.sh
git commit -m "feat(common): add migration fallback for old config path"
```

---

### Task 2: Migration script

**Files:**
- Create: `radarr/migrate_config.sh`

- [ ] **Step 1: Create the migration script**

```sh
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
echo "Optional: move shared vars (TMDB_API_KEY, YT_DLP_*, AUTOPULSE_*," >&2
echo "DRY_RUN, DEBUG) to common/scripts.conf for cross-app sharing." >&2
```

- [ ] **Step 2: Make executable and verify**

```bash
chmod +x radarr/migrate_config.sh
sh -n radarr/migrate_config.sh
shellcheck -e SC1091,SC3043 radarr/migrate_config.sh
```
All must exit 0.

- [ ] **Step 3: Test the happy path**

```bash
mkdir -p /tmp/migrate_test/radarr/connect
echo 'RADARR_API_KEY="test123"' > /tmp/migrate_test/radarr/connect/scripts.conf
cd /tmp/migrate_test && /Users/mvanbaak/dev/personal/arr_scripts/radarr/migrate_config.sh
cat /tmp/migrate_test/radarr/scripts.conf
# Expected: RADARR_API_KEY="test123"
rm -rf /tmp/migrate_test
```

- [ ] **Step 4: Test the "already migrated" path**

```bash
mkdir -p /tmp/migrate_test2/radarr/connect
echo 'RADARR_API_KEY="old"' > /tmp/migrate_test2/radarr/connect/scripts.conf
echo 'RADARR_API_KEY="new"' > /tmp/migrate_test2/radarr/scripts.conf
cd /tmp/migrate_test2 && /Users/mvanbaak/dev/personal/arr_scripts/radarr/migrate_config.sh 2>&1
# Expected: "Already migrated" message
rm -rf /tmp/migrate_test2
```

- [ ] **Step 5: Commit**

```bash
git add radarr/migrate_config.sh
git commit -m "feat(radarr): add config migration script"
```

---

### Task 3: Update README with migration section

**Files:**
- Modify: `README.md` (insert migration section after Quick start section)

- [ ] **Step 1: Add migration section to README**

Find the `## Quick start` section (the `cp` command block around line 40-43) and insert the migration section after the Quick start section ends (after the line saying `2. Set `RADARR_API_URL`...`), before the next `---` separator:

```markdown
### Migrating from old layout

If you updated from a version that stored config in `radarr/connect/scripts.conf`,
migrate to the new layout:

```sh
./radarr/migrate_config.sh
```

This copies your existing config to `radarr/scripts.conf` (new location).
The old file is kept as backup.

Scripts will still work with the old path via a temporary fallback, but
**this fallback will be removed in a future update** — migrate soon.

Optional: move shared settings (`TMDB_API_KEY`, `YT_DLP_*`, `AUTOPULSE_*`,
`DRY_RUN`, `DEBUG`) to `common/scripts.conf` for cross-app sharing.

```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(readme): add migration section for old config path"
```

---

### Task 4: Final verification

**Files:** (read-only verification)

- [ ] **Step 1: Full verification**

```bash
# Syntax check all scripts
sh -n common/scripts_common.sh
sh -n radarr/migrate_config.sh

# Shellcheck
shellcheck -e SC1091,SC3043 common/scripts_common.sh
shellcheck -e SC1091,SC3043 radarr/migrate_config.sh

# Grep for migration fallback in load_config
grep -n "migration fallback\|_old_conf\|_loaded" common/scripts_common.sh
```

- [ ] **Step 2: Push and update PR**

```bash
git push origin refactor/directory-structure
gh pr comment 8 --body "Added config migration fallback + migrate_config.sh. See README 'Migrating from old layout' section."
```
