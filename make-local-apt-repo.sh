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
##   - world-readable files  : else the `_apt` user cannot read them (N: note)
## Zero-Err: assumes Acquire::Languages "none" (Kicksecure/Whonix default); a stock
## apt also probes Translation-en and prints benign not-found Err: lines. See README.
##
## SECURITY: [trusted=yes] disables signature checking, so apt installs whatever
## is in REPO_DIR AS ROOT with no authentication. Point it ONLY at a path that is
## root-owned end to end (REPO_DIR and every ancestor). A REPO_DIR that is
## attacker-owned, a symlink into attacker space, or under a non-sticky
## attacker-owned parent lets a local user stage a package that apt then installs
## as root. For an untrusted or shared location, use the AUTHENTICATED recipe
## instead (sign a Release into InRelease + [signed-by=<keyring>]) -- see
## experiment/apt-repo-messages-test.sh variant E.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose
export LC_ALL=C

## Created dirs 755 and redirected files 644, so `_apt` can read the repo even
## when the caller's umask is restrictive (a 700 dir / 600 Packages re-triggers
## the very "couldn't be accessed by user '_apt'" note this tool avoids).
umask 022

repo_dir="${1:-/srv/myrepo}"
shift || true

if [ "$(id -u)" -ne 0 ]; then
   printf '%s\n' "$0: ERROR: run as root (writes ${repo_dir} and /etc/apt/sources.list.d)." >&2
   exit 1
fi

## REPO_DIR lands verbatim in a file: URI on a one-line sources.list entry, and apt
## percent-decodes it. Restrict to a safe absolute path -- leading slash, only
## [A-Za-z0-9._/-], no `//` or `..` component. This rejects whitespace and newlines
## (source injection), `%` (percent-decode traversal PAST the ownership check below),
## `#` (apt comment -> malformed entry), and a `//` prefix (invalid file: URI).
if [[ ! "${repo_dir}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
   printf '%s\n' "$0: ERROR: REPO_DIR must be an absolute path using only [A-Za-z0-9._/-]: ${repo_dir}" >&2
   exit 1
fi
if [[ "${repo_dir}" == *//* || "${repo_dir}" == */../* || "${repo_dir}" == */.. ]]; then
   printf '%s\n' "$0: ERROR: REPO_DIR must not contain '//' or a '..' component: ${repo_dir}" >&2
   exit 1
fi

## Lexically normalize (strip a trailing slash and any /./), WITHOUT resolving
## symlinks, so /srv/repo and /srv/repo/ map to one path -- otherwise they hash to
## two different list files and apt warns "configured multiple times".
repo_dir="$(realpath --no-symlinks --canonicalize-missing -- "${repo_dir}")"

## A symlink REPO_DIR could point [trusted=yes] into attacker-controlled space.
if [ -L "${repo_dir}" ]; then
   printf '%s\n' "$0: ERROR: REPO_DIR must not be a symlink: ${repo_dir}" >&2
   exit 1
fi

mkdir --parents -- "${repo_dir}"

## [trusted=yes] installs from REPO_DIR as root with no signature check, so a repo
## dir owned by, or writable by, a non-root user lets that user pre-seed or swap in
## a package apt then installs as root. Check the CURRENT (pre-existing) mode BEFORE
## the chmod below, or the chmod would mask a group/other-writable dir. (Ancestor
## dirs must be root-owned too -- the trust contract in the header; a full ancestor
## walk is out of scope here.)
repo_stat="$(stat --format='%u %a' -- "${repo_dir}")"
repo_owner="${repo_stat%% *}"
repo_mode="${repo_stat##* }"
if [ "${repo_owner}" -ne 0 ]; then
   printf '%s\n' "$0: ERROR: REPO_DIR must be root-owned for [trusted=yes]: ${repo_dir}" >&2
   exit 1
fi
if [ "$(( 0${repo_mode} & 022 ))" -ne 0 ]; then
   printf '%s\n' "$0: ERROR: REPO_DIR must not be group/other-writable (mode ${repo_mode}): ${repo_dir}" >&2
   exit 1
fi

## Now safe to ensure _apt can traverse/read it.
chmod 755 -- "${repo_dir}"

## Refuse any pre-existing symlink among the repo's files before staging or indexing:
## `cp` into a symlinked destination, `> Packages`, and the chown/chmod below would each
## follow it and read/alter a file OUTSIDE the repo. The dir is root-owned and not
## group/other-writable per the guard above, so only root could have placed one -- this
## closes the footgun rather than assuming it did not happen.
for existing in "${repo_dir}"/*.deb "${repo_dir}/Packages"; do
   if [ -L "${existing}" ]; then
      printf '%s\n' "$0: ERROR: refusing a symlink in REPO_DIR: ${existing}" >&2
      exit 1
   fi
done

## Stage any .deb arguments into the repo. Refuse a symlink argument: cp would follow
## it as root and copy the target's content (e.g. /etc/shadow) into a world-readable
## file. (A check/use race on an attacker-controlled ARGUMENT path is out of scope:
## the tool runs as root on operator-supplied arguments, the same trust as the path.)
for deb in "$@"; do
   if [ -L "${deb}" ]; then
      printf '%s\n' "$0: ERROR: refusing a symlink .deb argument (cp would follow it): ${deb}" >&2
      exit 1
   fi
   cp --verbose -- "${deb}" "${repo_dir}/"
done

if ! ls -- "${repo_dir}"/*.deb >/dev/null 2>&1; then
   printf '%s\n' "$0: ERROR: no .deb files in ${repo_dir} (pass some as arguments)." >&2
   exit 1
fi

## Plain uncompressed Packages: a gz-only index makes apt probe Packages.xz /
## .bz2 / .lzma first and print an Err: for each before falling back.
( cd -- "${repo_dir}" && dpkg-scanpackages . /dev/null > Packages )

## [trusted=yes] trusts these files: make them root-owned and world-readable so a
## pre-existing non-root owner cannot rewrite the package apt installs as root, and
## `_apt` can still read them.
chown --no-dereference root:root -- "${repo_dir}"/*.deb "${repo_dir}/Packages"
chmod 644 -- "${repo_dir}"/*.deb "${repo_dir}/Packages"

## List filename: unique per FULL path (two dirs sharing a basename must not collide
## and drop each other's entry) and bounded well under NAME_MAX. Prefixed so it
## cannot clobber a distro source (e.g. REPO_DIR=/srv/debian vs debian.list), and
## the basename is sanitized to apt's run-parts charset so it is never silently
## skipped (a space / leading dot).
repo_base="$(basename -- "${repo_dir}")"
repo_base="${repo_base:0:40}"
path_hash="$(printf '%s' "${repo_dir}" | sha256sum | cut -c1-12)"
list_name="local-apt-repo-$(printf '%s' "${repo_base}" | tr -c 'A-Za-z0-9_.-' '_')-${path_hash}"
list_file="/etc/apt/sources.list.d/${list_name}.list"
printf 'deb [trusted=yes] file:%s ./\n' "${repo_dir}" > "${list_file}"

printf '%s\n' "$0: INFO: wrote ${list_file}:"
cat -- "${list_file}"
printf '%s\n' "$0: INFO: run 'apt-get update' then 'apt-get install <pkg>'."
