# AGENTS.md - Agentic Coding Guidelines for arr_scripts

## Project Overview

This repository contains shell scripts and configuration files for Radarr automation.

**Scripts:**
- `radarr/connect/tag_dvfelmel.sh` - Tags movies with `fel` or `mel` based on Dolby Vision Enhancement Layer detection.
- `radarr/connect/download_trailer.sh` - Downloads official trailers from TMDB/YouTube for movies in Radarr.
- `radarr/connect/scripts_common.sh` - Shared library sourced by connect scripts (config loading, executable checks, Radarr API helpers).
- `radarr/auto_quality_switch.sh` - Switches movies from Remux-only to WebDL profiles when no physical release appears within a statistical threshold.
- `radarr/auto_quality_switch_reverse.sh` - Switches movies back to Remux-only when physical release dates appear for previously switched movies.

---

## Agent Behavior

### Workflow

1. **Brainstorm first.** Before any code change, discuss the idea with the user. Understand the problem, explore options, call out tradeoffs. Do not skip this step.
2. **Write a spec/proposal.** For non-trivial changes, write or update a spec document before implementing. The spec should cover: problem, design decisions, implementation plan, edge cases.
3. **Get approval.** Present the spec and wait for user approval before writing code.
4. **Implement.** Write the code following existing conventions.
5. **Update docs.** Update README.md with user-facing documentation for any new scripts or features. Only document what changed — no padding.
6. **Update AGENTS.md.** If new scripts, dependencies, or file organization changes, update this file. Skip if nothing relevant changed.
7. **Shellcheck.** Run `shellcheck -e SC1091,SC3043` on all modified scripts before committing.
8. **Commit and push.** Conventional Commits format. Push to the feature branch.
9. **Update PR.** Ensure the PR description and changelogs are current.

### Rules

- Always ask before making changes. Propose what you plan to do, wait for confirmation.
- Do not add comments, documentation, or configuration "for later" — only what is needed now.
- Do not add sections to AGENTS.md or README.md that just restate what the code already says.

---

## Build, Lint, and Test Commands

### Linting

**ShellCheck** - Static analysis for shell scripts:
```bash
shellcheck radarr/connect/tag_dvfelmel.sh
```

Run with specific rules disabled (as used in this project):
```bash
shellcheck -e SC1091,SC3043 radarr/connect/tag_dvfelmel.sh
```

### Scripts

**Run the tag script in test mode:**
```bash
./radarr/connect/tag_dvfelmel.sh
```

**Run in bulk mode (process all movies):**
```bash
./radarr/connect/tag_dvfelmel.sh bulk
```

**Direct invocation with arguments:**
```bash
./radarr/connect/tag_dvfelmel.sh <event_type> <movie_id> [movie_file_path]
```

Event types: `Test`, `MovieFileDelete`, `Download`, `Bulk`

**Run the trailer script in test mode:**
```bash
./radarr/connect/download_trailer.sh
```

**Run in bulk mode (process all movies):**
```bash
./radarr/connect/download_trailer.sh bulk
```

**Direct invocation with arguments:**
```bash
./radarr/connect/download_trailer.sh <event_type> <movie_id> [movie_path]
```

Event types: `Test`, `MovieAdded`, `Download`, `Bulk`

**Run the auto quality switch in dry-run mode:**
```bash
./radarr/auto_quality_switch.sh
```

**Run with apply flag:**
```bash
./radarr/auto_quality_switch.sh --apply
```

**Run migration mode:**
```bash
./radarr/auto_quality_switch.sh --migrate --apply
```

**Run the reverse script in dry-run mode:**
```bash
./radarr/auto_quality_switch_reverse.sh
```

**Run the reverse script with apply flag:**
```bash
./radarr/auto_quality_switch_reverse.sh --apply
```

### Testing

There are no formal test suites in this project. Manual testing can be performed by:
1. Running the script with `Test` event type
2. Using Radarr's built-in "Test" button for Connect scripts

---

## Code Style Guidelines

### Shell Script Conventions

- **Shebang:** Use `#!/usr/bin/env sh` for POSIX compatibility
- **Disable shellcheck warnings appropriately:** Add `# shellcheck disable=SCxxxx` comments when needed (e.g., `SC3043` for `local` keyword in POSIX sh)
- **Exit codes:** Use meaningful exit codes; 0 for success, 1 for general errors, 127 for command not found

### Formatting

- Indent with 4 spaces
- Maximum line length: 100 characters (soft limit)
- Use backslash for line continuation with proper indentation
- Pipe operators should have the pipe character at the end of the line, not the start

### Naming Conventions

- **Functions:** Use lowercase with underscores: `function_name()`
- **Variables:** Use uppercase for global variables, lowercase for locals
- **Constants:** All uppercase: `NEEDED_EXECUTABLES`
- **Local variables:** Prefix with underscore: `local _variable_name`
- **Configuration variables:** Prefix with service name: `RADARR_API_URL`

### Variable Declaration

```sh
# Global constants
NEEDED_EXECUTABLES="curl dovi_tool ffmpeg grep jq mktemp"

# Configuration with defaults
: "${LOG_FILE:=none}"
: "${RADARR_API_URL:=http://ip:7878/api/v3}"

# Local variables
local _movie_id _tag_id
```

### Error Handling

- Always redirect errors to stderr: `echo "ERROR: message" >&2`
- Use return codes to indicate success/failure
- Check command exit status when needed
- Provide meaningful error messages that include context

```sh
if ! command -v "${executable}" >/dev/null 2>&1
then
    echo "ERROR: Executable '${executable} not found." >&2
    exit 127
fi
```

### Input Validation

- Validate function arguments with case statements
- Check for empty strings: `[ -z "$var" ]`
- Validate numeric input using pattern matching:

```sh
case "$1" in
    ''|*[!0-9]*)
        echo "ERROR: Argument is not a movie id: $1" >&2
        return 1
        ;;
    *)
        _movie_id="$1"
        ;;
esac
```

### API Interactions

- Use curl with `-s` for silent operation
- Always set headers: `Accept-Encoding`, `Content-Type`
- Parse JSON responses with jq
- Use printf for JSON payloads to avoid injection issues

### Function Structure

```sh
function_name() {
    local _arg1 _arg2

    # Input validation
    case "$1" in
        '')
            echo "ERROR: Missing required argument" >&2
            return 1
            ;;
    esac

    # Main logic
    # ...

    # Return result
    echo "${_result}"
}
```

### Comments

- Use comments to explain non-obvious logic
- Document function purpose at the top
- Reference external sources when basing code on others' work

### Changelog Headers

Every script must have a versioned changelog in its header comment block.
- Bump version when adding features or fixing behavior (MAJOR.MINOR.PATCH)
- Add new version block ABOVE the previous one (newest first)
- Prefix each change with `#   * ` for consistent formatting
- Use format: `# Version X.Y.Z (Released YYYY-MM-DD)`
- List user-facing changes, not implementation details

### Configuration Files

- Sample files should have `.sample` extension
- Document all configuration variables with comments
- Use descriptive variable names
- Place sensitive defaults (like API keys) with placeholder values

### Best Practices

- Check for required executables at script start
- Use mktemp for temporary files; always clean up
- Quote all variable expansions: `"$variable"`
- Use `$()` for command substitution (not backticks)
- Use arithmetic expansion: `$((_counter+=1))`
- Be careful with word splitting - always quote variables
- Use meaningful debug messages: `echo "DEBUG: Doing X for Y"`

---

## Commit Conventions

This project uses [Conventional Commits](https://www.conventionalcommits.org/).

### Format

```
<type>: <description>
```

### Types

- `fix:` - Bug fixes
- `feat:` - New features
- `perf:` - Performance improvements
- `refactor:` - Code restructuring without behavior change
- `style:` - Formatting, naming, or cosmetic changes
- `docs:` - Documentation changes
- `chore:` - Maintenance, tooling, or config changes

### Guidelines

- One logical change per commit
- Keep the subject line concise (imperative mood)
- Scope is optional but encouraged for clarity (e.g., `fix(rpu): ...`)
- Tag releases with annotated tags: `git tag -a <version> -m "Release <version>"`

---

## File Organization

```
radarr/connect/
  scripts_common.sh    # Shared library (sourced by all scripts)
  tag_dvfelmel.sh      # Dolby Vision FEL/MEL tagging script
  download_trailer.sh  # Trailer download script
  scripts.conf.sample  # Sample configuration
  scripts.conf         # Actual configuration (not in git)

radarr/
  auto_quality_switch.sh          # Forward script: Remux-only → WebDL
  auto_quality_switch_reverse.sh  # Reverse script: WebDL → Remux-only

docs/
  quality-switch-spec.md          # Forward script specification
  quality-switch-reverse-spec.md  # Reverse script specification
  cookie-extraction.md            # Guide for exporting YouTube cookies for yt-dlp
```

---

## Dependencies

Required executables for `tag_dvfelmel.sh` (checked at runtime):
- curl
- dovi_tool
- ffmpeg
- grep
- jq
- mktemp

Required executables for `download_trailer.sh` (checked at runtime):
- curl
- cut
- ffmpeg
- jq
- mkdir
- mktemp
- tr
- yt-dlp

Required executables for `auto_quality_switch.sh` and `auto_quality_switch_reverse.sh` (checked at runtime):
- curl
- jq

---

## Notes

- For more extensive Radarr taggers, check out [Radarr DV HDR Tagarr](https://github.com/TRaSH-/Starr-taggers#radarr-dv-hdr-tagarr) from TRaSH-
- Scripts are designed to run in Radarr Connect/post-process context
- Compatible with FreeBSD and Linux environments

Respond terse like smart caveman. All technical substance stay. Only fluff die.

Rules:
- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan
Stop: "stop caveman" or "normal mode"

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/commits/PRs written normal.
