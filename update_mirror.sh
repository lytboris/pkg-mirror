#!/bin/sh

set -e
# sh ./update_mirror.sh pkg.freebsd.org/FreeBSD:14:powerpc/kmods_quarterly_4

REPOURL=$1

# Validate argument: must have the form host/ABI/repo
case "${REPOURL}" in
	*/*/*) ;;
	*)
		echo "Usage: $0 <host>/<ABI>/<repo>" >&2
		echo "Example: $0 pkg.freebsd.org/FreeBSD:14:amd64/quarterly" >&2
		exit 1
		;;
esac

OIFS="${IFS}"
IFS="/"

set -- $1

IFS="${OIFS}"

ZFSROOT="pkgmirror/$1"
# Derive skel root from the ZFS pool name to avoid hardcoding an absolute path
ZFSPOOL="${ZFSROOT%%/*}"
SKELREPODIR="/${ZFSPOOL}/skel/${REPOURL}"
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
mkdir -p "${REPOS_DIR}"

export PKG_DBDIR="/${ZFSROOT}/../.db/${REPOURL}"
mkdir -p "${PKG_DBDIR}"


# Phase 1. Import file-based repo
cat > "${REPOS_DIR}/repo.conf" <<ENDL
repo: {
	url: "file://${REPOLOCALROOT}",
	enabled: yes
}
ENDL

export DEFAULT_ALWAYS_YES=YES
export ASSUME_ALWAYS_YES=YES
pkg update -f -r "repo"

# Phase 2. Download packages
cat > "${REPOS_DIR}/repo.conf" <<ENDL
repo: {
	url: "https://${REPOURL}",
	enabled: yes
}
ENDL

# A dirty hack to keep repo's meta files in sync
# This
# 1) evades us from "Repository %s has a wrong packagesite, need to re-create database"
# 2) forces pkg to download packages specified in pre-downloaded repository metadata
sqlite3 "${PKG_DBDIR}/repos/repo/db" "UPDATE repodata SET value='https://${REPOURL}' WHERE key='packagesite';"

pkg fetch -Uays -o "${REPOLOCALROOT}" -r "repo"

sqlite3 "${PKG_DBDIR}/repos/repo/db" "UPDATE repodata SET value='https://${REPOLOCALROOT}' WHERE key='packagesite';"

cat > "${REPOS_DIR}/repo.conf" <<ENDL
repo: {
	url: "file://${REPOLOCALROOT}",
	enabled: yes
}
ENDL

pkg update -f -r "repo"

#
# Description: Creates hardlinks from the Hashed directory to the parent directory and removes broken symlinks.
#              This function handles package repositories that use content-addressable storage where files
#              are stored in a Hashed subdirectory and hardlinked to their actual locations.
# Parameters:
#   $1 - Path to the repository directory (e.g., "/pkgmirror/pkg.freebsd.org/FreeBSD:14:amd64/quarterly")
# Returns:
#   0 - Success
#
hardlink_hashed()
{
	CDIR=$(pwd)
	# skip if Hashed dir is not in use for this repo
	if [ -d "$1/All/Hashed" ]; then
		cd "$1/All";
	elif [ -d "$1/Hashed" ]; then
		cd "$1";
	else
		return 0;
	fi

	relinked=0
	for item in `find Hashed -type f`; do
		ln -f "${item}" .;
		relinked=$((relinked+1))
	done
	broken_links=0
	for item in `find ./ -depth 1 -type l`; do
		if [ -r "${item}" ]; then continue; fi
		rm "${item}";
		broken_links=$((broken_links+1))
	done
	cd "${CDIR}"
	echo "Relinked ${relinked} files, removed ${broken_links} broken symlinks"
}

#
# Description: Cleans up obsolete files from a package repository by comparing current files with
#              the target repository state. This function performs a full repository recreation
#              when more than 1/3 of files are obsolete (older than 1 month).
# Parameters:
#   $1 - Path to the local repository directory to clean (e.g., "/pkgmirror/pkg.freebsd.org/FreeBSD:14:amd64/quarterly")
#   $2 - Path to the skeleton repository directory used as template (e.g., "/pkgmirror/skel/pkg.freebsd.org/FreeBSD:14:amd64/quarterly")
# Returns:
#   0 - Success
#
cleanup_repo()
{
	# skel for this repo is not available
	[ -d "$2" ] || return 0;

	# BSD wc -l pads output with spaces; use $((...)) to coerce to integer
	TARGET_NFILES=$(pkg rquery -U -r "repo" '%n' | wc -l)
	[ $((TARGET_NFILES)) -gt 100 ] || return 0;

	CURRENT_NFILES=$(find "$1" -not -type d -and -not -newerat '1 month ago' | wc -l)
	[ $((CURRENT_NFILES)) -gt 100 ] || return 0;

	# at least 1/3 of files is obsolete
	[ $((3*CURRENT_NFILES)) -gt $((TARGET_NFILES)) ] || return 0

	printf '\n\n!!! Cleanup is needed: current_files=%s, target_files=%s\n\n' \
		"${CURRENT_NFILES}" "${TARGET_NFILES}"

	CDIR=$(pwd)
	cd "$1"
	# a "new" repo is born
	NREPODIR="$1/.newrepo"
	mkdir -p "${NREPODIR}"
	tar -C "$2" -cf - . | tar -C "${NREPODIR}" -xpf -
	lockf -k /tmp/recreate-all.lock pkg fetch -Uqays -o "${NREPODIR}" -r "repo"
	hardlink_hashed "${NREPODIR}"

	# now scan new repo for obsolete files located in the real repo
	# broken symlinks will be deleted by hardlink_hashed
	deleted=0
	for item in `find ./ -not -type d -and -not -newerat '1 month ago'`; do
		if [ -r "${NREPODIR}/${item}" ]; then continue; fi
		deleted=$((deleted+1))
		rm "${item}"
	done
	cd "${CDIR}"
	rm -r "${NREPODIR}"

	echo "Deleted ${deleted} files";

	return 0;
}

# Phase 3. Cleanup repo from obsolete files/links if needed
cleanup_repo "${REPOLOCALROOT}" "${SKELREPODIR}"

# Phase 4. Add missing, remove broken symlinks: symlink every file in Hashed to an upper layer
hardlink_hashed "${REPOLOCALROOT}"

exit 0;
