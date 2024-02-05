#!/bin/sh -e

PROGRAM="$(readlink -nf "$0")";
PROGRAM_DIR="$(dirname "$PROGRAM")";
SOURCE_DIR="$(readlink -nf "$PROGRAM_DIR/..")";
GENTOO_ROOT="$SOURCE_DIR/.gentoo-chroot";
REPO_OWNER="$(stat -c '%U' "$SOURCE_DIR")"; # GET USER FROM REPO OWNERSHIP

_perror(){
	test "${VERBOSE:=1}" -ge 1 || return 0;
	test -n "$LN" && printf '%s' "Error@$LN" >&2 || printf 'Error' >&2;
	printf "%s\n" ": $1" >&2;
	shift;
	while test "$#" -gt 0; do
		printf "\t%s\n" "$1" >&2;
		shift;
	done;
};

ensure_key(){
	gpg --list-keys releng@gentoo.org > /dev/null || \
	gpg --import-keys releng@gentoo.org; # 2 pass error suppression
}

verify_key(){
	gpg --verify "$1" "$2";
}

latest_stage3(){
	curl -#L "$1/latest-stage3-amd64-openrc.txt" | \
			gpg -d 2>/dev/null | \
			grep -Poe '^[^# ]+(?= [0-9])';
}

guestsync(){
	while test "$#" -gt 0; do
		cp -v "$1" "$GENTOO_ROOT/$1";
		shift;
	done;
}

uidmap_hack(){
	seq 1 10000 | \
		sed -Ee "s/(.+)/--map-groups \\1:$(id -u):1 --map-users \\1:$(id -u):1 /";
	#id -G | tr ' ' '\n' | sed -Ee "s/(.+)/--map-groups \\1:\\1:1 /";
	:;
}

stage2(){
	# NOTE: This should only ever be run from within the new unshare userspace.

	# Truncate first IFS which has no data.
	BIND_HOST="${BIND_HOST%:}";
	BIND_GUEST="${BIND_GUEST%:}";
	while test -n "${BIND_HOST##*:}"; do
		host_path="${BIND_HOST##*:}";
		guest_path="${BIND_GUEST##*:}";
		
		mkdir -p "$guest_path";
		mount -vo bind "$host_path" "$guest_path";

		BIND_HOST="${BIND_HOST%"$host_path"}";
		BIND_GUEST="${BIND_GUEST%"$guest_path"}";	
		
		BIND_HOST="${BIND_HOST%:}";
		BIND_GUEST="${BIND_GUEST%:}";
	done;

	cd "$GENTOO_ROOT";
	#mount -t proc none "$GENTOO_ROOT/proc";
	mount -t tmpfs none "$GENTOO_ROOT/run";
	mount -t tmpfs none "$GENTOO_ROOT/tmp"
	mount --rbind /sys "$GENTOO_ROOT/sys";
	mount --rbind /dev "$GENTOO_ROOT/dev";

	# Ensure the network works properly. Basically coppied straight from proot
	guestsync \
		/etc/resolv.conf \
		/etc/nsswitch.conf \
		/etc/host.conf \
		/etc/hosts \
		/etc/localtime;

	# NOTE: Recommended by the Gentoo handbook.
	mkdir -p "$GENTOO_ROOT/etc/portage/repos.conf";
	if ! test -e "$GENTOO_ROOT/etc/portage/repos.conf/gentoo.conf"; then
		cp "$GENTOO_ROOT/usr/share/portage/config/repos.conf" \
			"$GENTOO_ROOT/etc/portage/repos.conf/gentoo.conf";
	fi;

	#mkdir -p "$GENTOO_ROOT/usr/lib/libfakeroot";
	#mount -o bind /usr/lib/libfakeroot "$GENTOO_ROOT/usr/lib/libfakeroot";
	
	exec chroot "$GENTOO_ROOT" /bin/env TERM="linux" /bin/bash -l <&0;

	# NOTE: No need to clean up the mounts, after dropping out of the unshared
	# mount namespace, the mounts established within it will be unmounted
	# automatically.
}

# XXX: Eazy hack on non-posix systems which support $LINENO for debugging.
alias perror='LN="$LINENO"; _perror';

if test "$STAGE2" = "JFrVlIQwCagtOtgA0wlC4gjauHNBXX9ca"; then
	stage2;
fi;

REBUILD='false';
CLEAN='false';
BOUND='';
OPTARG='';
OPTIND='';
#trap "cleanup;" SIGINT SIGKILL 0;
while getopts ":RCB:" flag; do
	case "$flag" in
		'R') REBUILD='true';;
		'C') CLEAN='true';;
		'B')
			host_path="$(readlink -fn "${OPTARG%:*}")";
			guest_path="$(readlink -fn "$GENTOO_ROOT/${OPTARG#*:}")";
			BIND_HOST="$BIND_HOST:$host_path";
			BIND_GUEST="$BIND_GUEST:$guest_path";
		;;
		'?')
			cat << EOF
USAGE: build.sh [-CR]";
DESCRIPTION:
  Manages the Gentoo chroot responsible for building packages which require
  advanced dependency management.
ARGUMENTS:
  -R > Rebuild; when the chroot is already built, will remove the existing
       chroot and rebuild it from scratch.
  -C > Clean; removes the chroot from existence.
  -B > Binds a host path to a chroot path in the form of HOST_PATH:GUEST_PATH
       similar to \`proot\`.
EOF
		exit;
		;;
	esac;
done;

#https://gentoo.osuosl.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt
GENTOO_MIRROR='distfiles.gentoo.org';
GENTOO_ARCH='amd64';
GENTOO_BUILD="https://$GENTOO_MIRROR/releases/$GENTOO_ARCH/autobuilds";
#GENTOO_STAGE3="$GENTOO_STAGE3/stage3-amd64-openrc-20240121T170320Z.tar";

if ! ensure_key; then
	perror "refusing to continue; no pathway to validate incoming files.";
	exit 1;
fi;

cd "$SOURCE_DIR";
if $REBUILD; then
	rm -vrf "$GENTOO_ROOT";
fi;
if $CLEAN; then
	rm -vrf "$GENTOO_ROOT";
	exit 0;
fi;
mkdir -p "$GENTOO_ROOT";
if ! test -f "$GENTOO_ROOT/.complete" || $REBUILD; then 
	cd "$GENTOO_ROOT";
	echo "discovering latest Stage3 location";
	archive="$(latest_stage3 "$GENTOO_BUILD")";
	
	echo "fetching: $GENTOO_BUILD/$archive";
	curl -#LO "$GENTOO_BUILD/$archive";
	echo "fetching: $GENTOO_BUILD/$archive.asc";
	curl -#LO "$GENTOO_BUILD/$archive.asc";

	archive="${archive##*/}";
	if verify_key "$archive.asc" "$archive"; then
		# Extracts into . unlike source repos.
		tar --skip-old-files --exclude "*dev/*" -xJvf "$archive";
		touch ".complete";
	else
		perror "refusing to continue; stage3 archive couldn't be validated!";
		exit 1;
	fi;
	rm "$archive" "$archive.asc";
fi;

# TODO: add in mount options into the unshare and then chroot.
export STAGE2="JFrVlIQwCagtOtgA0wlC4gjauHNBXX9ca";
export BIND_HOST;
export BIND_GUEST;
unshare -UCrfmp \
	--mount-proc="$GENTOO_ROOT/proc" \
	--propagation=private \
	--kill-child=SIGKILL \
	"$PROGRAM";
