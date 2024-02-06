#!/usr/bin/env -S pkexec --keep-cwd --disable-internal-agent sh -e

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

cleanup(){
	BOUND="${BOUND%:}"; # Truncate first IFS which has no data.
	while test -n "${BOUND##*:}"; do
		guest_path="${BOUND##*:}";
		if umount -vf "$guest_path"; then :;
		elif test "$?" -eq "32"; then
			echo "Warning: problem unmounting guest path; falling back to a lazy" >&2;
			printf "\tunmount, you must now reboot before restarting the chroot!" >&2;
			printf '\n' >&2;
			umount -vl "$guest_path";
		fi
		BOUND="${BOUND%"$guest_path"}";
		BOUND="${BOUND%:}";
	done;
}

# Drops root privleges temporaryily for the contents of stdin.
odus(){ su -s '/bin/sh' "$REPO_OWNER" <&0; };

ensure_key(){ cat << ENSURE | odus;
	gpg --list-keys releng@gentoo.org > /dev/null || \
	gpg --list-keys releng@gentoo.org;
ENSURE
}

verify_key(){ cat << VERIFY | odus;
	gpg --verify "$1" "$2";
VERIFY
}

guestsync(){
	while test "$#" -gt 0; do
		cp -v "$1" "$GENTOO_ROOT/$1";
		shift;
	done;
}

guestmount(){
	while test "$#" -gt 0; do
		BOUND="$BOUND:$GENTOO_ROOT/$1";
		mount -vo bind "/$1" "$GENTOO_ROOT/$1";
		shift;
	done;
}

# XXX: Eazy hack on non-posix systems which support $LINENO for debugging.
alias perror='LN="$LINENO"; _perror';

# Proot automatically changes to $PWD so it may look like Jail escape
# when it's not.
## XXX: NOTABUG/WONTFIX???: https://github.com/proot-me/proot/issues/66
## NOTE: emerge won't work inside Proot. May require modification.
#proot \
#	-b "$BUILD_DIR/initramfs:/mnt/build" \
#	-R ./gentoo-chroot \
#	./gentoo-chroot/bin/env \
#		PATH='/bin:/usr/bin:/usr/local/bin' \
#		TERM='linux' \
#		sh -c "cd \"$(readlink -fn ./gentoo-chroot)\"; exec bash;" << BUILD_EOF
#		emerge --sync
#		emerge --root=/mnt/build cryptsetup bash
#BUILD_EOF

REBUILD='false';
CLEAN='false';
BOUND='';
OPTARG='';
OPTIND='';
trap "cleanup;" SIGINT SIGKILL 0;
while getopts ":RCB:" flag; do
	case "$flag" in
		'R') REBUILD='true';;
		'C') CLEAN='true';;
		'B')
			host_path="$(readlink -fn "${OPTARG%:*}")";
			guest_path="$(readlink -fn "$GENTOO_ROOT/${OPTARG#*:}")";
			mkdir -p "$guest_path";
			mount -vo bind "$host_path" "$guest_path";
			BOUND="$BOUND:$GENTOO_ROOT/${OPTARG#*:}";
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

# XXX: BUG: Sometimes chroot dev will be mounted as true dev instead of -B
#   bound to /dev in the filesystem. This is erronious behavior and causes
#   the intended bound "$GENTOO_ROOT/dev" to refuse unmounting.
guestmount /dev /proc /sys /tmp /run;

# Ensure the network works properly. Basically coppied straight from proot
guestsync \
	/etc/resolv.conf \
	/etc/nsswitch.conf \
	/etc/host.conf \
	/etc/hosts \
	/etc/localtime;

P='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin';
chroot \
	--userspec=0:0 "$GENTOO_ROOT" \
	/usr/bin/env \
		ROOTPATH="$P" \
		PATH="$P" \
		TERM='linux' \
		MANPAGER='manpager' \
		/bin/bash <&0;
