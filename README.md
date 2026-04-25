A couple of scripts that came handy for mirroring binary package collections
for FreeBSD.

Alpha-quality code, use it on your own risk! (PRs are welcome, though).

To run these skripts, one should
* have some spare disk space on a ZFS pool
* install py311-requests to mirror metadata of repositories
* install a web server for distibuting packages if needed

## update_mirror.sh
Scripts updates a single repository. To do that, metadata for a reposiory
should be present.


## batch.sh
Scripts scraps
1) `pkg.freebsd.com` for repositories available
2) Runs `update_mirror.sh` for each repository created
3) If `update_mirror.sh` is successful, publishes it using zfs
snapshot/clone.


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
