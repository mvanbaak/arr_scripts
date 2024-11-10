# arr_scripts
Random collection of scripts and configuration files used by *arr tools in my setup

## radarr/connect

Script and supporting files to be used as Connect / postprocess scripts in radarr.

### scripts.conf.sample

Configuration file used by all Connect scripts

### tag_dvfelmel.sh

Script to be run with:
- On File Import
- On File Upgrade
- On Movie File Delete

Script will tag the movie with `fel` or `mel` if the file
contains a Dolby Vision Enhancement Layer, and wether the EL
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
