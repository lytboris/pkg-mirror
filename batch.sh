#!/bin/sh

ZFSROOT="pkgmirror"
WWWROOT="${ZFSROOT}/www"
LOGSDST="/${WWWROOT}/pkg.freebsd.org/logs"

# build base tree
update_skel()
{
	echo "Updating skel with wget";
	wget -o "$1" -e robots=off -R 'FreeBSD*.pkg,*.html*,*=*' -r -l inf -E -np 'https://pkg.freebsd.org/'
	WGETEXITCODE=$?
	echo -e "=====================================\n\n"
	set -e
	case "${WGETEXITCODE}" in
		0) ;;
		8)
			echo "Ignore exit code 8 (Server issued an error response), special thanks to cloudfront issuing a 403";
			;;
		*)
			echo "wget stage failure, exit code $?, please investigate. Log is saved to ${LOGFILE}"
			exit ${WGETEXITCODE}
	esac
}


mirror_releng()
{
	echo "Start mirror releng $1 sync @ ${DATETIME} (${TIMESTAMP})"
	echo "List of repositories that were not updated due to an error can be found at the end of this log."

	fail=""
	for ABI in `find pkg.freebsd.org -type d -name "*:$1:*" -depth 1`; do
		if ! zfs get -H name "${WWWROOT}/${ABI}" >/dev/null 2>&1; then
			echo zfs create "${WWWROOT}/${ABI}"
		fi
		for REPO in `find ${ABI} -type d -depth 1`; do
			echo -e "=====================================\n\n"
			echo "Updating ${REPO}"
			if ! sh ./update_mirror.sh ${REPO}; then
				fail="${fail} ${REPO}"
				continue;
			fi
			echo "Switching ${REPO} snapshot"
			SNAP_NAME="${ZFSROOT}/${REPO}@${TIMESTAMP}"
			CLONE_NAME="${WWWROOT}/${REPO}"
			zfs snapshot "${SNAP_NAME}"
			if zfs get -H name "${CLONE_NAME}" >/dev/null 2>&1; then
				zfs destroy "${CLONE_NAME}"
			fi
			zfs clone -o 'readonly=on' "${SNAP_NAME}" "${CLONE_NAME}"
		done
	done
	echo -e "=====================================\n\n"
	if [ -n "${fail}" ]; then
		echo -e "Failed repos: ${fail}"
	else
		echo -e "All good!"
	fi
	cp ${LOGFILE} "/${LOGSDST}"
	return 0;
}


TIMESTAMP=$(date -j '+%s')
DATETIME=$(date)
LOGFILE="logs/batch.txt"
WGETLOGFILE="logs/wget-repo-mirror.txt"

exec >"${LOGFILE}" 2>&1
mkdir -p logs;

case "X$1" in
	X[0-9]*)
		LOGFILE="logs/batch-$1.txt";
		exec >"${LOGFILE}" 2>&1
		mirror_releng "$1"
		exit $?;
		;;
	X|X[Ww][Gg][Ee][Tt][Oo][Nn][Ll][Yy])
		update_skel "${WGETLOGFILE}";
		cp "${WGETLOGFILE}" "${LOGSDST}"
		if [ -n "$1" ]; then
			cp "${LOGFILE}" "${LOGSDST}"
			exit 0;
		fi
		;;
	*) ;;
esac


for releng in `find pkg.freebsd.org -type d -depth 1 | cut -f 2 -d: | sort -u`; do
	screen -d -m lockf -t0 "/tmp/pkg-sync-${releng}.lock" sh "$0" "${releng}"
done
cp "${LOGFILE}" "${LOGSDST}"
exit 0;
