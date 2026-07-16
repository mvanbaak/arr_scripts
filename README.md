# arr_scripts

Random collection of scripts and configuration files used by *arr tools in my setup

### auto_quality_switch.sh

Automatically switches movies from a Remux-only profile to a WebDL-enabled
profile when no physical release appears within a statistically determined
threshold (P95 of the web-to-physical gap, computed from your own library).

Movies that wait longer than the threshold for a physical release are
unlikely to ever get one. The script switches their profile so Radarr can
grab a WebDL release instead of leaving them in permanent limbo.

#### Prerequisites

- `curl` and `jq` 1.6+ (installed by default on most systems)
- Radarr API URL and key configured in `scripts.conf`

Install `jq` if missing:

```sh
# FreeBSD
pkg install jq

# Debian / Ubuntu
apt install jq

# Fedora / RHEL
dnf install jq

# macOS
brew install jq
```

#### Quick start

1. Copy and edit the config:

```sh
cp radarr/connect/scripts.conf.sample radarr/connect/scripts.conf
```

2. Set `RADARR_API_URL` and `RADARR_API_KEY` in `scripts.conf`.
   Set `SOURCE_PROFILE_NAME` and `TARGET_PROFILE_NAME` to match your
   Radarr quality profile names exactly (case-sensitive).

3. Run in dry-run mode (default) to preview what would switch:

```sh
./radarr/auto_quality_switch.sh
```

4. Run with `--apply` to actually switch profiles:

```sh
./radarr/auto_quality_switch.sh --apply
```

#### Migration mode

After initial setup, run `--migrate` once to fix existing movies that
already have downloaded files on the wrong profile:

```sh
# Preview what migration would do
./radarr/auto_quality_switch.sh --migrate

# Apply migration
./radarr/auto_quality_switch.sh --migrate --apply
```

Migration checks each movie's file quality source:
- **WebDL/WebRip files** — switches profile automatically
- **Other files** (Bluray, Remux, HDTV, etc.) — logged to stderr for
  manual review

Migration never triggers search — review the logged movies first.

#### Flags

| Flag | Effect |
|------|--------|
| `--apply` | Actually switch profiles (overrides `DRY_RUN` config) |
| `--migrate` | One-time library migration mode |
| `-n`, `--dry-run` | Preview mode, no changes (default) |
| `-j`, `--json` | Output machine-readable JSON |
| `-q`, `--quiet` | Only errors and counts, no per-movie list |
| `-d`, `--debug` | Verbose debug logging to stderr |

#### Scheduling

Add to crontab for daily automated runs:

```cron
# Dry-run first — review the log for a week
0 6 * * * /path/to/radarr/auto_quality_switch.sh >> /var/log/quality-switch.log 2>&1

# Then switch to apply mode
0 6 * * * /path/to/radarr/auto_quality_switch.sh --apply >> /var/log/quality-switch.log 2>&1
```

---

### auto_quality_switch_reverse.sh

Switches movies back to Remux-only profiles when physical release dates
appear for movies previously switched by the forward script. Uses a Radarr
tag (`auto-switched`) to track which movies were switched.

Run weekly — physical releases don't appear daily.

#### Quick start

1. Uses the same `scripts.conf` as the forward script.
2. Preview candidates:

```sh
./radarr/auto_quality_switch_reverse.sh
```

3. Apply reverse switch:

```sh
./radarr/auto_quality_switch_reverse.sh --apply
```

The reverse script switches the profile and triggers a search for the
Remux release. Radarr handles the rest — downloads the Remux, removes
the old WebDL file.

#### Scheduling

```cron
# Weekly, Sunday at 7am
0 7 * * 0 /path/to/radarr/auto_quality_switch_reverse.sh --apply >> /var/log/quality-switch-reverse.log 2>&1
```

#### Flags

Same as the forward script (see table above), except `--migrate` is not
available on the reverse script.

---

### scripts.conf.sample

Configuration file used by all Connect scripts and the auto quality switch
scripts. Copy to `scripts.conf` and edit:

```sh
cp radarr/connect/scripts.conf.sample radarr/connect/scripts.conf
```

See the sample file for all available settings with documentation.

---

## Contributing

This project follows [Conventional Commits](https://www.conventionalcommits.org/) and the conventions documented in [AGENTS.md](AGENTS.md).

## Looking for more extensive Radarr taggers?

If you need more features or better maintained taggers, check out the [Radarr DV HDR Tagarr](https://github.com/TRaSH-/Starr-taggers#radarr-dv-hdr-tagarr) from TRaSH-. It offers more extensive functionality and active development.

## radarr/connect

Script and supporting files to be used as Connect / postprocess scripts in radarr.

### tag_dvfelmel.sh

Script to be run with:
- On File Import
- On File Upgrade
- On Movie File Delete

Script will tag the movie with `fel` or `mel` if the file
contains a Dolby Vision Enhancement Layer, and whether the EL
is minimal or full.
If the imported file has no Enhancement Layer, and the movie has one of
those two tags, it will be removed.

The script can also be run as:
```sh
$ ./tag_dvfelmel.sh bulk
```
If run like this, it will loop over all movies in radarr
and add/remove the tags where needed. Can be used to backfill
all the tags for an existing library.

### download_trailer.sh

Script to be run with:
- On Movie Add
- On File Import
- On File Upgrade

Script will search TMDB for official trailers for the movie and download
them in the best available quality using yt-dlp.
Trailers are saved in a `Trailers/` subdirectory inside the movie folder.

By default it downloads trailers in the movie's original language and
Brazilian Portuguese (pt-BR), with Brazilian Portuguese subtitles for
original-language trailers. These preferences can be configured in
`scripts.conf`.

Requires a TMDB API key (set `TMDB_API_KEY` in `scripts.conf`).
Get one at https://www.themoviedb.org/settings/api

For age-restricted content, YouTube cookie authentication is supported.
See [cookie extraction guide](docs/cookie-extraction.md) for setup.

The script can also be run as:
```sh
$ ./download_trailer.sh bulk
```
If run like this, it will loop over all movies in radarr
and download trailers where needed. Can be used to backfill
trailers for an existing library.
