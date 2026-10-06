#!/bin/bash

## Regression test for make-local-apt-repo.sh REPO_DIR validation.
##
## Runs as ANY user and touches no filesystem: it drives the target in validate-only
## mode (LOCAL_APT_REPO_VALIDATE_ONLY=1), which checks REPO_DIR and exits before the
## root check and before any mkdir/cp/apt action.
##
## Canary (prove it is RED on code without the guard): point it at a pre-guard
## revision and run as a NON-root user --
##   git show <pre-guard-rev>:make-local-apt-repo.sh > /tmp/pre.sh
##   TARGET_SCRIPT=/tmp/pre.sh bash test/test-repo-dir-validation.sh
## That revision lacks the validate-only seam, so it falls through to the root check
## and a bad path emits "run as root" instead of the guard error -- failing the reject
## assertions (which key on the guard's error TEXT, not merely a non-zero exit).

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose
export LC_ALL=C

script_dir="$(dirname -- "$(realpath -- "$0")")"
target="${TARGET_SCRIPT:-${script_dir}/../make-local-apt-repo.sh}"

## Emitted only by the two path-validation guards (charset and `//`/`.`/`..`); in
## validate-only mode no other error path is reachable.
guard_signature='ERROR: REPO_DIR must'

fail_count=0
out=''
rc=0

run_validate() {
   ## Validate-only: the target checks REPO_DIR and exits before the root check and any
   ## filesystem action, so this is safe and uid-independent. Sets globals `out`/`rc`.
   rc=0
   out="$(LOCAL_APT_REPO_VALIDATE_ONLY=1 bash -- "${target}" "$1" 2>&1)" || rc=$?
}

expect_reject() {
   local path="$1" label="$2"
   run_validate "${path}"
   if [ "${rc}" -ne 0 ] && [[ "${out}" == *"${guard_signature}"* ]]; then
      printf 'PASS  reject  %s\n' "${label}"
   else
      printf 'FAIL  reject  %s  (rc=%s, out=%q)\n' "${label}" "${rc}" "${out}" >&2
      fail_count=$(( fail_count + 1 ))
   fi
}

expect_accept() {
   local path="$1" label="$2"
   run_validate "${path}"
   if [ "${rc}" -eq 0 ]; then
      printf 'PASS  accept  %s\n' "${label}"
   else
      printf 'FAIL  accept  %s  (rc=%s, out=%q)\n' "${label}" "${rc}" "${out}" >&2
      fail_count=$(( fail_count + 1 ))
   fi
}

## Reject battery: every class the review flagged, plus percent / dotdot / dot / hash / `//`.
expect_reject 'myrepo'          'relative path'
expect_reject '/'               'bare slash'
expect_reject '/srv/my repo'    'embedded space'
printf -v newline_path '/srv/x\ndeb [trusted=yes] file:/srv/injected ./'
expect_reject "${newline_path}" 'newline source injection'
expect_reject '/srv/a%2e%2e/x'  'percent-encoded'
expect_reject '/srv/../x'       'dotdot component'
expect_reject '/.'              'dot collapses to root'
expect_reject '/./'             'dot-slash collapses to root'
expect_reject '/srv/./x'        'embedded dot component'
expect_reject '/srv/a#b'        'hash (apt comment)'
expect_reject '//srv/x'         'double leading slash'

## Clean absolute paths must pass validation (a `.` inside a name is not a component).
expect_accept '/srv/myrepo'     'clean absolute path'
expect_accept '/srv/my.repo'    'dot inside a path component'
expect_accept '/srv/.cache/r'   'leading-dot (hidden) directory'

## The seam activates ONLY on the literal value 1, so an inherited `=0` ("disabled")
## cannot turn a real run into a success no-op. Observable only by letting a clean path
## fall through past the seam, which needs a non-root run; skip (honestly) under root.
if [ "$(id -u)" -ne 0 ]; then
   rc=0
   out="$(LOCAL_APT_REPO_VALIDATE_ONLY=0 bash -- "${target}" /srv/myrepo 2>&1)" || rc=$?
   if [ "${rc}" -ne 0 ] && [[ "${out}" != *"${guard_signature}"* ]]; then
      printf 'PASS  seam-gate  LOCAL_APT_REPO_VALIDATE_ONLY=0 does not no-op\n'
   else
      printf 'FAIL  seam-gate  =0 wrongly activated the seam (rc=%s, out=%q)\n' "${rc}" "${out}" >&2
      fail_count=$(( fail_count + 1 ))
   fi
else
   printf 'SKIP  seam-gate  (run as root; needs a non-root fall-through)\n'
fi

if [ "${fail_count}" -ne 0 ]; then
   printf '\n%s: FAIL: %s assertion(s) failed\n' "$0" "${fail_count}" >&2
   exit 1
fi
printf '\n%s: PASS: all REPO_DIR validation assertions held\n' "$0"
