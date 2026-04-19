#!/bin/sh

set -e
# sh ./update_mirror.sh pkg.freebsd.org/FreeBSD:14:powerpc/kmods_quarterly_4

REPOURL=$1

OIFS="${IFS}"
IFS="/"

set -- $1

IFS="${OIFS}"

ZFSROOT="pkgmirror/$1"
SKELREPODIR="/pkgmirror/skel/${REPOURL}"
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

sqlite3 "${PKG_DBDIR}/repos/repo/db" "UPDATE repodata SET value='https://${REPOLOCALROOT}' WHERE key='packagesite';"

cat > ${REPOS_DIR}/repo.conf <<ENDL
repo: {
	url: "file://${REPOLOCALROOT}",
	enabled: yes
}
ENDL

pkg update -f -r "repo"

# Phase 3. Cleanup repo from obsolete files/links if needed
cleanup_repo()
{
	# skel for this repo is not available
	[ -d "$2" ] || return 0;

	TARGET_NFILES=$(pkg rquery -U -r "repo" '%n' | wc -l)
	CURRENT_NFILES=$(find "$1" -type f | wc -l)

	[ ${TARGET_NFILES} -gt 100 ] || return 0;
	[ ${CURRENT_NFILES} -gt 100 ] || return 0;

	# at least 1/3 of files is obsolete
	[ $((3*(CURRENT_NFILES-TARGET_NFILES))) -gt ${TARGET_NFILES} ] || return 0

	echo -e "\n\n!!! Cleanup is needed: current_files=${CURRENT_NFILES}, target_files=${TARGET_NFILES}\n";

	CDIR=$(pwd)
	FILELIST=$(mktemp)
	cd "$1"
	# make file list
	find ./ -type f > ${FILELIST}
	# a "new" repo is born
	NREPODIR="$1/.newrepo"
	mkdir -p "${NREPODIR}"
	tar -C "$2" -cf - . | tar -C ${NREPODIR} -xpf -
	lockf -k /tmp/recreate-all.lock pkg fetch -Uqays -o ${NREPODIR} -r "repo"

	# now scan new repo for obsolete files located in the real repo
	for item in `cat "${FILELIST}"`; do
		[ -r "${NREPODIR}/${item}" ] || rm "${item}"
	done
	cd "${CDIR}"
	rm -r "${NREPODIR}"
	rm ${FILELIST}

	return 0;
}

cleanup_repo "${REPOLOCALROOT}" "${SKELREPODIR}"

exit 0;
