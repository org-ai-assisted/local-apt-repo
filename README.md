# local-apt-repo

A local flat `file:` apt repository, scripted end to end, plus a catalog of the
confusing `apt-get update` messages such a repo produces on modern apt and how to
get rid of them.

Tested on Debian 13 (trixie), **apt 3.0.3**.

## TL;DR: the clean recipe

`make-local-apt-repo.sh` builds a message-free local repo. The essence:

```sh
mkdir -p /srv/myrepo && chmod 755 /srv/myrepo        # 755 so user '_apt' can read it
cp *.deb /srv/myrepo/
cd /srv/myrepo
dpkg-scanpackages . /dev/null > Packages             # PLAIN Packages, not gz-only
echo 'deb [trusted=yes] file:/srv/myrepo ./' > /etc/apt/sources.list.d/local.list
apt-get update
```

Resulting `apt-get update` output (no `E:` / `W:` / `N:`, no `Err:`):

```
Ign:1 file:/srv/myrepo ./ InRelease
Ign:2 file:/srv/myrepo ./ Release
Get:3 file:/srv/myrepo ./ Packages
Reading package lists...
```

The two `Ign:` lines are normal and harmless: apt looks for a signed `InRelease`
and a `Release`, finds neither, and ignores them because the source is
`[trusted=yes]`.

## Why the naive recipe is noisy (or fails) on modern apt

The classic advice (`dpkg-scanpackages . /dev/null | gzip > Packages.gz`, then a
bare `deb file:/... ./` line) no longer just warns on apt 3.0 -- it hard-fails,
and even the fixes have a subtle noise trap. Measured behavior:

| config | `apt-get update` result |
| --- | --- |
| bare `deb file:/... ./`, no Release, no trust | FAILS: `E: ... does not have a Release file.` |
| `Release` present but unsigned, no trust | FAILS: `E: ... is not signed.` |
| `deb [trusted=yes] file:/... ./` | clean, works |
| `Release` + `[trusted=yes]` | clean, works |
| signed `InRelease` + `[signed-by=<keyring>]` | clean, works, authenticated |

Three separate causes of "confusing messages", each with a fix:

1. **Refuse-by-default.** apt 3.0 refuses an unsigned/unauthenticated repo with a
   fatal `E:`, not a warning. Fix: mark it `[trusted=yes]` (local/throwaway) or
   sign it and use `[signed-by=<keyring>]` (proper).
2. **Compression-probe noise.** Shipping only `Packages.gz` makes apt probe
   `Packages.xz`, `.bz2`, `.lzma` first and print `Err: File not found` for each
   before falling back. Fix: ship a plain uncompressed `Packages` file.
3. **`_apt` permission note.** If the repo dir is not readable by the `_apt`
   user (e.g. under `$HOME` at mode 700, or `/root`), apt prints
   `N: Download is performed unsandboxed as root ... couldn't be accessed by
   user '_apt'`. Fix: keep the repo dir world-readable (e.g. `/srv/myrepo`, 755).

## Two supported configs

- **Throwaway / local only:** `[trusted=yes]`. No `Release`, no key needed.
  `make-local-apt-repo.sh` produces this.
- **Authenticated:** generate `Release`, sign it into `InRelease`, reference the
  public key with `[signed-by=/etc/apt/keyrings/<name>.gpg]`. No deprecated
  `apt-key`. See `experiment/apt-repo-messages-test.sh` variant E for the exact
  commands.

## Files

- `make-local-apt-repo.sh` -- build a clean, message-free local repo from a set
  of `.deb` files (the recommended recipe).
- `experiment/apt-repo-messages-test.sh` -- the investigation harness: builds a
  dummy package (via Kicksecure `helper-scripts`' `dummy-dependency` tool when
  present, else `equivs-build`), then runs `apt-get update` across five configs
  (A-E) in an isolated apt state and reports which messages each emits.

## Reproducing the investigation

```sh
sudo bash experiment/apt-repo-messages-test.sh
```

Runs entirely under `/srv/local-apt-repo-test` with an isolated apt lists/state
dir, so the system's real apt configuration is never touched.
