#!/bin/bash

## Regression test for make-local-apt-repo.sh REPO_DIR validation.
##
## Runs as ANY user: the validated allowlist is a pure string check placed before the
## root check, so it needs no privileges and touches no filesystem (the script exits
## at the guard or, for a clean path, at the unrelated root check -- never reaching
## mkdir/cp/apt).
##
## Canary: point it at a pre-validation revision to confirm it goes RED --
##   git show <pre-guard-rev>:make-local-apt-repo.sh > /tmp/pre.sh
##   TARGET_SCRIPT=/tmp/pre.sh bash test/test-repo-dir-validation.sh
## Assertions key on the guard's error TEXT, not the exit code: a non-root run of an
## unguarded script still exits non-zero (its "run as root" check), so an exit-only
## assertion would false-pass on the broken code.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
shopt -s inherit_errexit
shopt -s shift_verbose
export LC_ALL=C

script_dir="$(dirname -- "$(realpath -- "$0")")"
target="${TARGET_SCRIPT:-${script_dir}/../make-local-apt-repo.sh}"

## Emitted only by the two path-validation guards (charset and `//`/`..`).
guard_signature='ERROR: REPO_DIR must'

fail_count=0
out=''
rc=0

run_target() {
   ## Capture combined output + exit code without tripping errexit on the expected
   ## non-zero exit. Sets globals `out` and `rc`.
   rc=0
   out="$(bash -- "${target}" "$1" 2>&1)" || rc=$?
}

expect_reject() {
   local path="$1" label="$2"
   run_target "${path}"
   if [ "${rc}" -ne 0 ] && [[ "${out}" == *"${guard_signature}"* ]]; then
      printf 'PASS  reject  %s\n' "${label}"
   else
      printf 'FAIL  reject  %s  (rc=%s, out=%q)\n' "${label}" "${rc}" "${out}" >&2
      fail_count=$(( fail_count + 1 ))
   fi
}

expect_pass_guard() {
   local path="$1" label="$2"
   run_target "${path}"
   if [[ "${out}" == *"${guard_signature}"* ]]; then
      printf 'FAIL  accept  %s  (path guard fired: %q)\n' "${label}" "${out}" >&2
      fail_count=$(( fail_count + 1 ))
   else
      printf 'PASS  accept  %s\n' "${label}"
   fi
}

## Reject battery: every class the review flagged, plus percent / dotdot / hash / `//`.
expect_reject 'myrepo'          'relative path'
expect_reject '/'               'bare slash'
expect_reject '/srv/my repo'    'embedded space'
printf -v newline_path '/srv/x\ndeb [trusted=yes] file:/srv/injected ./'
expect_reject "${newline_path}" 'newline source injection'
expect_reject '/srv/a%2e%2e/x'  'percent-encoded'
expect_reject '/srv/../x'       'dotdot component'
expect_reject '/srv/a#b'        'hash (apt comment)'
expect_reject '//srv/x'         'double leading slash'

## A clean absolute path must clear the guard (it then stops at the unrelated root check).
expect_pass_guard '/srv/myrepo' 'clean absolute path'

if [ "${fail_count}" -ne 0 ]; then
   printf '\n%s: FAIL: %s assertion(s) failed\n' "$0" "${fail_count}" >&2
   exit 1
fi
printf '\n%s: PASS: all REPO_DIR validation assertions held\n' "$0"
