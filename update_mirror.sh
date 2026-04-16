#!/bin/sh

set -e
# sh ./update_mirror.sh pkg.freebsd.org/FreeBSD:14:powerpc/kmods_quarterly_4

REPOURL=$1

OIFS="${IFS}"
IFS="/"

set -- $1

IFS="${OIFS}"

ZFSROOT="pkgmirror/$1"
export ABI=$2
REPO=$3
REPOLOCALROOT="/${ZFSROOT}/${ABI}/${REPO}"

echo "${REPOURL}: storing packages into ${REPOLOCALROOT}"

# check if we are running on a separate zfs filesystems
if ! zfs get -H mountpoint "${ZFSROOT}/${ABI}" >/dev/null; then
	mv "/${ZFSROOT}/${ABI}" "/${ZFSROOT}/${ABI}.tmp"
	zfs create "${ZFSROOT}/${ABI}"
	tar -C "/${ZFSROOT}/${ABI}.tmp" -cf - . | tar -C "/${ZFSROOT}/${ABI}" -xpf - 
	rm -r "/${ZFSROOT}/${ABI}.tmp"
fi
if ! zfs get -H mountpoint "${ZFSROOT}/${ABI}/${REPO}" >/dev/null; then
	mv "/${ZFSROOT}/${ABI}/${REPO}" "/${ZFSROOT}/${ABI}/${REPO}.tmp"
	zfs create "${ZFSROOT}/${ABI}/${REPO}"
	tar -C "/${ZFSROOT}/${ABI}/${REPO}.tmp" -cf - . | tar -C "/${ZFSROOT}/${ABI}/${REPO}" -xpf - 
	rm -r "/${ZFSROOT}/${ABI}/${REPO}.tmp"
fi

export REPOS_DIR="/${ZFSROOT}/../.repocfg/${REPOURL}"
mkdir -p ${REPOS_DIR}

export PKG_DBDIR="/${ZFSROOT}/../.db/${REPOURL}"
mkdir -p ${PKG_DBDIR}

PACKAGE_DIR=/${ZFSROOT}/${ABI}/${REPO}


# Phase 1. Import file-based repo
cat > ${REPOS_DIR}/repo.conf <<ENDL
repo: {
	url: "file://${REPOLOCALROOT}",
	enabled: yes
}
ENDL

export DEFAULT_ALWAYS_YES=YES
export ASSUME_ALWAYS_YES=YES
pkg update -f -r "repo"

# Phase 2. Download packages
cat > ${REPOS_DIR}/repo.conf <<ENDL
repo: {
	url: "https://${REPOURL}",
	enabled: yes
}
ENDL

# A dirty hack to keep repo's meta files in sync
# This
# 1) evades us from "Repository %s has a wrong packagesite, need to re-create database"
# 2) forces pkg to download packages specified in pre-downloaded repositoty metadata
sqlite3 "${PKG_DBDIR}/repos/repo/db" "UPDATE repodata SET value='https://${REPOURL}' WHERE key='packagesite';"

pkg fetch -Uays -o ${REPOLOCALROOT} -r "repo"
