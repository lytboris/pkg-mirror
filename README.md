A couple of scripts that came handy for mirroring binary package collections
for FreeBSD.

Alpha-quality code, use it on your own risk! (PRs are welcome, though).

## Dependencies

* ZFS pool with sufficient free space (see [Space requirements](#space-requirements))
* `pkg` — FreeBSD package manager (used for fetching and querying)
* `sqlite3` — for patching the pkg database between sync phases
* `screen` — for running per-releng syncs in parallel (used by `batch.sh`)
* `lockf` — for advisory locking (ships with FreeBSD base)
* Python 3.11+ with `requests` library:
  ```sh
  pkg install py311-requests
  ```
* A web server for distributing packages (optional, e.g. nginx or Apache)

## Scripts

### pymirror.py

Crawls `pkg.freebsd.org` and mirrors the directory skeleton (HTML index pages
and small metadata files) into a local `skel/` tree. Large `.pkg` files are
intentionally skipped — they are downloaded later by `update_mirror.sh` via
`pkg fetch`.

```sh
python pymirror.py https://pkg.freebsd.org skel/pkg.freebsd.org
python pymirror.py --debug https://pkg.freebsd.org skel/pkg.freebsd.org
```

### update_mirror.sh

Updates a single repository. Requires the skeleton metadata to be present
(populated by `pymirror.py` / `batch.sh --wget-only`).

```sh
sh ./update_mirror.sh pkg.freebsd.org/FreeBSD:14:amd64/quarterly
```

### batch.sh

1. Crawls `pkg.freebsd.org` for available repositories (`pymirror.py`)
2. Runs `update_mirror.sh` for each repository
3. On success, publishes the result via ZFS snapshot + clone (read-only)

```sh
# Full run (crawl metadata + sync all releng branches in parallel)
sh batch.sh

# Crawl metadata only, then exit
sh batch.sh --wget-only

# Sync packages only (skip metadata crawl)
sh batch.sh --no-wget

# Sync a specific release branch only
sh batch.sh 14
sh batch.sh --no-wget 14
```

## ZFS layout

The scripts expect the following ZFS dataset layout:

```
pkgmirror/                         # ZFSROOT pool
pkgmirror/pkg.freebsd.org/         # per-host datasets
pkgmirror/pkg.freebsd.org/FreeBSD:14:amd64/quarterly
pkgmirror/www/                     # public read-only clones (WWWROOT)
pkgmirror/www/pkg.freebsd.org/FreeBSD:14:amd64/quarterly
```

Snapshots are kept for 7 days and then destroyed automatically.

## Space requirements

As of April, 2026:
```
NAME                                               USED
pkgmirror/pkg.freebsd.org                         6.02T
pkgmirror/pkg.freebsd.org/FreeBSD:13:i386          605G
pkgmirror/pkg.freebsd.org/FreeBSD:14:i386          728G
pkgmirror/pkg.freebsd.org/FreeBSD:13:amd64         574G
pkgmirror/pkg.freebsd.org/FreeBSD:14:amd64         982G
pkgmirror/pkg.freebsd.org/FreeBSD:15:amd64         582G
pkgmirror/pkg.freebsd.org/FreeBSD:16:amd64         248G
pkgmirror/pkg.freebsd.org/FreeBSD:13:aarch64       469G
pkgmirror/pkg.freebsd.org/FreeBSD:14:aarch64       789G
pkgmirror/pkg.freebsd.org/FreeBSD:16:aarch64       135G
pkgmirror/pkg.freebsd.org/FreeBSD:15:aarch64       432G
pkgmirror/pkg.freebsd.org/FreeBSD:13:armv6        86.2G
pkgmirror/pkg.freebsd.org/FreeBSD:14:armv6        48.1G
pkgmirror/pkg.freebsd.org/FreeBSD:13:armv7         168G
pkgmirror/pkg.freebsd.org/FreeBSD:14:armv7         191G
pkgmirror/pkg.freebsd.org/FreeBSD:15:armv7        88.5G
pkgmirror/pkg.freebsd.org/FreeBSD:16:armv7        4.01G
pkgmirror/pkg.freebsd.org/FreeBSD:14:powerpc      6.00G
pkgmirror/pkg.freebsd.org/FreeBSD:14:powerpc64    6.88G
pkgmirror/pkg.freebsd.org/FreeBSD:15:powerpc64    3.14G
pkgmirror/pkg.freebsd.org/FreeBSD:16:powerpc64    3.66G
pkgmirror/pkg.freebsd.org/FreeBSD:14:powerpc64le  6.78G
pkgmirror/pkg.freebsd.org/FreeBSD:15:powerpc64le  3.15G
pkgmirror/pkg.freebsd.org/FreeBSD:16:powerpc64le  3.66G
```
