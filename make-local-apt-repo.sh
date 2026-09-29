#!/bin/bash

## Build a clean, message-free local flat apt repository from a set of .deb files.
##
## Usage:
##   sudo bash make-local-apt-repo.sh [REPO_DIR] [DEB ...]
##
## Defaults: REPO_DIR=/srv/myrepo. If no DEBs are given, any *.deb already in
## REPO_DIR is indexed.
##
## Produces a repo that `apt-get update` reads with no E:/W:/N: and no Err: probe
## noise. The three things that keep it quiet:
##   - [trusted=yes]        : apt 3.0 refuses an unsigned repo with a fatal E:
##   - plain `Packages`      : gz-only makes apt probe .xz/.bz2/.lzma and print Err:
##   - world-readable dir    : else the `_apt` user cannot read it (N: note)
##
## For an AUTHENTICATED repo instead, sign a Release into InRelease and use
## [signed-by=<keyring>] -- see experiment/apt-repo-messages-test.sh variant E.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose
export LC_ALL=C

repo_dir="${1:-/srv/myrepo}"
shift || true

if [ "$(id -u)" -ne 0 ]; then
   printf '%s\n' "$0: ERROR: run as root (writes ${repo_dir} and /etc/apt/sources.list.d)." >&2
   exit 1
fi

## 755 so the unprivileged `_apt` user can read the repo (avoids the
## "couldn't be accessed by user '_apt'" note).
mkdir --parents -- "${repo_dir}"
chmod 755 -- "${repo_dir}"

## Stage any .deb arguments into the repo.
for deb in "$@"; do
   cp --verbose -- "${deb}" "${repo_dir}/"
done

if ! ls -- "${repo_dir}"/*.deb >/dev/null 2>&1; then
   printf '%s\n' "$0: ERROR: no .deb files in ${repo_dir} (pass some as arguments)." >&2
   exit 1
fi

## Plain uncompressed Packages: a gz-only index makes apt probe Packages.xz /
## .bz2 / .lzma first and print an Err: for each before falling back.
( cd -- "${repo_dir}" && dpkg-scanpackages . /dev/null > Packages )

list_file="/etc/apt/sources.list.d/$(basename -- "${repo_dir}").list"
printf 'deb [trusted=yes] file:%s ./\n' "${repo_dir}" > "${list_file}"

printf '%s\n' "$0: INFO: wrote ${list_file}:"
cat -- "${list_file}"
printf '%s\n' "$0: INFO: run 'apt-get update' then 'apt-get install <pkg>'."
