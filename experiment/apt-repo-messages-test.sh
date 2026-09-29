#!/bin/bash

## Investigation harness: build a local flat apt repo, run `apt-get update` under
## five configs, and catalog which messages each emits. Run as root:
##
##   sudo bash experiment/apt-repo-messages-test.sh
##
## Everything lives under WORK (root-owned, 755 -> _apt-readable). apt is pointed
## at an isolated sources file + lists/state dir, so the system's real apt state
## is never touched; cleanup is a recursive remove of WORK.
##
## A failing `apt-get update` is a RESULT to capture, not an abort: every command
## whose non-zero exit is expected is guarded (if/else or `|| ...`), so errexit
## stays on without swallowing the results the harness exists to record.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose
export LC_ALL=C

## Portable demo: must run on a plain Debian box, so no Kicksecure-only helpers.
## style-ok: no-safe-rm
## style-ok: no-has
## style-ok: allow-echo
## style-ok: allow-apt-get

WORK=/srv/local-apt-repo-test
REPO="${WORK}/repo"
LISTS="${WORK}/lists"
LOGDIR="${WORK}/logs"
KEYDIR="${WORK}/keys"
GNUPGHOME="${KEYDIR}/gnupg"
export GNUPGHOME

declare -A RC     # per-variant apt-get update exit code (source of truth)

hr() { printf '\n============================================================\n%s\n============================================================\n' "$1"; }

if [ "$(id -u)" -ne 0 ]; then
   printf '%s\n' "$0: ERROR: run as root." >&2
   exit 1
fi

## --- clean slate ---------------------------------------------------------
rm -rf "${WORK}"
mkdir -p "${REPO}" "${LISTS}" "${LOGDIR}" "${KEYDIR}"
chmod 755 "${WORK}" "${REPO}" "${LISTS}" "${LOGDIR}"

## --- deps: apt-ftparchive (apt-utils) + gnupg for the signed variant -----
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends apt-utils gnupg >/dev/null 2>&1 \
   || echo "WARN: apt-utils/gnupg install had issues"

## --- step 1: dummy .deb --------------------------------------------------
## Prefer Kicksecure helper-scripts' dummy-dependency (a root wrapper around
## equivs-build); fall back to equivs-build directly.
hr "STEP 1: build dummy package"
PKG=dummy-dependency-test
if command -v dummy-dependency >/dev/null 2>&1; then
   dummy-dependency --cache-only dependency-test
   cp -v /var/lib/dummy-dependency/dummy-dependency-test_99_all.deb "${REPO}/"
elif command -v equivs-build >/dev/null 2>&1; then
   stub="${WORK}/${PKG}.equivs"
   cat > "${stub}" <<EOF
Package: ${PKG}
Version: 1.0
Architecture: all
Maintainer: local-apt-repo test <test@example.com>
Description: Dummy package for local apt repo testing
EOF
   ( cd "${WORK}" && equivs-build "${stub}" )
   cp -v "${WORK}/${PKG}"_*_all.deb "${REPO}/"
else
   echo "ERROR: neither dummy-dependency nor equivs-build available" >&2
   exit 1
fi
chmod 644 "${REPO}"/*.deb

## --- step 2: flat repo indices ------------------------------------------
## Plain Packages avoids apt's .xz/.bz2/.lzma compression-probe noise; a .gz is
## kept alongside to show it does no harm when the plain file is also present.
hr "STEP 2: dpkg-scanpackages"
( cd "${REPO}" && dpkg-scanpackages . /dev/null > Packages 2> "${LOGDIR}/scan.stderr" )
gzip -9c "${REPO}/Packages" > "${REPO}/Packages.gz"
cat "${LOGDIR}/scan.stderr"
ls -l "${REPO}"

## --- isolated apt-get update runner -------------------------------------
run_update() {
   local name="$1" line="$2"
   local sl="${WORK}/sources-${name}.list"
   local ld="${LISTS}/${name}"
   printf '%s\n' "${line}" > "${sl}"
   rm -rf "${ld}"; mkdir -p "${ld}/partial"; chmod 755 "${ld}" "${ld}/partial"
   hr "VARIANT ${name}: ${line}"
   local rc
   ## `if` condition suppresses errexit, so a refused repo (exit 100) is captured
   ## rather than aborting the run.
   if apt-get update \
      -o Dir::Etc::sourcelist="${sl}" \
      -o Dir::Etc::sourceparts="/dev/null" \
      -o Dir::State::lists="${ld}" \
      -o APT::Get::List-Cleanup="0" \
      > "${LOGDIR}/${name}.log" 2>&1
   then
      rc=0
   else
      rc=$?
   fi
   RC[${name}]="${rc}"
   echo "exit=${rc}"
   cat "${LOGDIR}/${name}.log"
   LAST_LD="${ld}"; LAST_SL="${sl}"
}

run_update A "deb file:${REPO} ./"
run_update B "deb [trusted=yes] file:${REPO} ./"

hr "generate Release (apt-ftparchive release)"
( cd "${REPO}" && apt-ftparchive release . > Release 2> "${LOGDIR}/ftparchive.stderr" )
cat "${LOGDIR}/ftparchive.stderr"

run_update C "deb file:${REPO} ./"
run_update D "deb [trusted=yes] file:${REPO} ./"

## E: sign it. Throwaway ed25519 key -> clearsigned InRelease, public key exported
## as a keyring referenced via signed-by (no deprecated apt-key).
hr "STEP: local GPG sign -> InRelease + signed-by keyring"
mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"
cat > "${KEYDIR}/keyparams" <<'EOF'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Name-Real: Local Test Repo
Expire-Date: 0
%commit
EOF
gpg --batch --gen-key "${KEYDIR}/keyparams" 2> "${LOGDIR}/gpg-gen.log" \
   || { echo "gpg keygen FAILED"; cat "${LOGDIR}/gpg-gen.log"; }
gpg --export > "${KEYDIR}/local-test.gpg" 2>/dev/null
( cd "${REPO}" && gpg --batch --yes --clearsign -o InRelease Release 2> "${LOGDIR}/gpg-sign.log" ) \
   || { echo "gpg sign FAILED"; cat "${LOGDIR}/gpg-sign.log"; }
run_update E "deb [signed-by=${KEYDIR}/local-test.gpg] file:${REPO} ./"

## --- verify the package actually resolves under config E ----------------
hr "VERIFY: apt-cache policy + install --dry-run (config E)"
apt-cache policy "${PKG}" \
   -o Dir::Etc::sourcelist="${LAST_SL}" \
   -o Dir::Etc::sourceparts="/dev/null" \
   -o Dir::State::lists="${LAST_LD}" 2>&1
apt-get install --dry-run "${PKG}" \
   -o Dir::Etc::sourcelist="${LAST_SL}" \
   -o Dir::Etc::sourceparts="/dev/null" \
   -o Dir::State::lists="${LAST_LD}" 2>&1

## --- honest summary: pass/fail + noise per variant ----------------------
## A variant is CLEAN only if rc=0 AND no E:/W:/N: line. E: is fatal, so counting
## only W:/N: would report a hard failure as clean.
declare -A DESC=(
   [A]="bare flat repo, no Release, no trust"
   [B]="[trusted=yes], no Release"
   [C]="Release present, unsigned, no trust"
   [D]="Release + [trusted=yes]"
   [E]="signed InRelease + [signed-by=keyring]"
)
hr "SUMMARY: per-variant result (rc = apt-get update exit code)"
for v in A B C D E; do
   rc="${RC[${v}]:-?}"
   ## `|| true`: grep -c exits 1 when the count is 0, which errexit would abort on.
   noise="$(grep -E -c '^[EWN]:' "${LOGDIR}/${v}.log" 2>/dev/null || true)"
   noise="${noise:-0}"
   if [ "${rc}" = 0 ] && [ "${noise}" = 0 ]; then
      verdict="CLEAN"
   else
      verdict="NOT CLEAN"
   fi
   printf '>>> %s  rc=%s  msgs=%s  %-9s  (%s)\n' "${v}" "${rc}" "${noise}" "${verdict}" "${DESC[${v}]}"
   grep -E '^[EWN]:' "${LOGDIR}/${v}.log" 2>/dev/null | sed 's/^/      /' || true
done
hr "DONE"
