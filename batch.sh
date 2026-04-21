#!/bin/sh

usage()
{
	cat <<EOF
Usage: $0 [OPTION] [RELENG]

Options:
  --wget-only   Run wget/update_skel stage only, then exit
  --no-wget     Skip wget/update_skel stage
  --help or -h  Show this help and exit

Arguments:
  RELENG        Numeric release branch to mirror (example: 13)

Examples:
  $0 --wget-only
  $0 --no-wget
  $0 13
  $0 --no-wget 13
EOF
}

DO_WGET=1
WGET_ONLY=0
RELENG_ARG=

ZFSROOT="pkgmirror"
WWWROOT="${ZFSROOT}/www"
LOGSDST="/${WWWROOT}/pkg.freebsd.org/logs"

# build base tree
update_skel()
{
	echo "Updating skel with wget"
	mkdir -p skel || exit 1
	cd skel || exit 1

	wget -o "../$1" \
		-e robots=off \
		-R 'FreeBSD*.pkg,*=*,Freebsd*.html' \
		-r -l inf -E -np \
		'https://pkg.freebsd.org/'

	WGETEXITCODE=$?

	cd .. || exit 1

	printf '=====================================\n\n'

	set -e

	case "${WGETEXITCODE}" in
		0)
			;;
		8)
			echo "Ignore exit code 8 (Server issued an error response), special thanks to cloudfront issuing a 403"
			;;
		*)
			echo "wget stage failure, exit code ${WGETEXITCODE}, please investigate. Log is saved to ${LOGFILE}"
			exit "${WGETEXITCODE}"
			;;
	esac

	tar -C skel -cf - . | tar -xpf -
}

mirror_releng()
{
	set -e

	echo "Start mirror releng $1 sync @ ${DATETIME} (${TIMESTAMP})"
	echo "List of repositories that were not updated due to an error can be found at the end of this log."

	fail=""

	for ABI in `find pkg.freebsd.org -type d -name "*:$1:*" -depth 1`; do
		if ! zfs get -H name "${WWWROOT}/${ABI}" >/dev/null 2>&1; then
			zfs create "${WWWROOT}/${ABI}"
		fi

		for REPO in `find "${ABI}" -type d -depth 1`; do
			printf '=====================================\n\n'
			echo "Updating ${REPO}"

			if ! sh ./update_mirror.sh "${REPO}"; then
				echo "Update failed for ${REPO}"
				fail="${fail} ${REPO}"
				continue
			fi

			echo "Switching ${REPO} snapshot"

			SNAP_NAME="${ZFSROOT}/${REPO}@${TIMESTAMP}"
			CLONE_NAME="${WWWROOT}/${REPO}"

			zfs snapshot "${SNAP_NAME}"

			if zfs get -H name "${CLONE_NAME}" >/dev/null 2>&1; then
				zfs destroy "${CLONE_NAME}"
			fi

			zfs clone -o readonly=on "${SNAP_NAME}" "${CLONE_NAME}"

			for oldsnap in `zfs list -H -o name -t snap -r "${ZFSROOT}/${REPO}"`; do
				if [ "X${oldsnap}" = "X${SNAP_NAME}" ]; then
					continue
				fi

				SNAP_CREATED=`zfs get -Hp creation -o value "${oldsnap}"`

				if [ -n "${SNAP_CREATED}" ] &&
				   [ `expr "${SNAP_CREATED}" + 86400` -gt "${TIMESTAMP}" ]; then
					echo "Keep snapshot ${oldsnap}"
					continue
				fi

				if zfs destroy "${oldsnap}"; then
					echo "Destroyed ${oldsnap}"
				else
					echo "There was an error destroying ${oldsnap}, please investigate"
				fi
			done
		done
	done

	printf '=====================================\n\n'

	if [ -n "${fail}" ]; then
		echo "Failed repos:${fail}"
	else
		echo "All good!"
	fi

	cp "${LOGFILE}" "${LOGSDST}"
	return 0
}

TIMESTAMP=`date -j '+%s'`
DATETIME=`date`
LOGFILE="logs/batch.txt"
WGETLOGFILE="logs/wget-repo-mirror.txt"

while [ $# -gt 0 ]; do
	case "$1" in
		--wget-only)
			WGET_ONLY=1
			if [ ${DO_WGET} -eq 0 ]; then
				usage;
				exit 1;
			fi
			;;
		--no-wget)
			DO_WGET=0
			;;
		--help|-h)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		[0-9]*)
			RELENG_ARG=$1
			;;
		-*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			;;
	esac
	shift
done

mkdir -p logs || exit 1
exec >"${LOGFILE}" 2>&1

if [ "${DO_WGET}" -eq 1 ]; then
	update_skel "${WGETLOGFILE}"
	cp "${WGETLOGFILE}" "${LOGSDST}"
fi

if [ "${WGET_ONLY}" -eq 1 ]; then
	cp "${LOGFILE}" "${LOGSDST}"
	exit 0;
fi

if [ -n "${RELENG_ARG}" ]; then
	LOGFILE="logs/batch-${RELENG_ARG}.txt"
	exec >"${LOGFILE}" 2>&1
	mirror_releng "${RELENG_ARG}"
	exit $?
fi

for releng in `find pkg.freebsd.org -type d -depth 1 | cut -f 2 -d: | sort -u`; do
	screen -d -m lockf -k -t0 "/tmp/pkg-sync-${releng}.lock" \
		sh "$0" --no-wget "${releng}"
done

cp "${LOGFILE}" "${LOGSDST}"
exit 0
