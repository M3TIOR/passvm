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
		recurse='';
		guest_path="${BOUND##*:}";
		#case "$guest_path" in
		#	"$GENTOO_ROOT//dev")
		#		recurse="R";
		#	;;
		#esac;
		if umount -vf"$recurse" "$guest_path"; then :;
		elif test "$?" -eq "32"; then
			echo "Warning: problem unmounting guest path; falling back to a lazy" >&2;
			printf "\tunmount, you must now reboot before restarting the chroot!" >&2;
			printf '\n' >&2;
			umount -vl "$guest_path";
		fi;
		BOUND="${BOUND%"$guest_path"}";
		BOUND="${BOUND%:}";
	done;

	rm -f "$PENV";
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

bindmount(){
	OPTARG="$*";
	host_path="$(readlink -fn "${OPTARG%:*}")";
	guest_path="$(readlink -fn "$GENTOO_ROOT/${OPTARG#*:}")";
	if ! test -d "$host_path"; then
		perror "$host_path is not a valid directory!";
		exit 1;
	fi;
	mkdir -p "$guest_path";
	mount -vo bind "$host_path" "$guest_path";
	BOUND="$BOUND:$GENTOO_ROOT/${OPTARG#*:}";
}

guestmount(){
	guest_path="$(eval echo "\$$#")";
	BOUND="$BOUND:$GENTOO_ROOT/$guest_path";
	mount -v ${@%"$guest_path"} "$GENTOO_ROOT/$guest_path";
}

print_help(){ cat << EOF
USAGE: build.sh [-CR] [-B H:G []]";
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
}


# XXX: Eazy hack on non-posix systems which support $LINENO for debugging.
alias perror='LN="$LINENO"; _perror';

# NOTE: make sure we clean up after ourselves
trap "cleanup;" SIGINT SIGKILL 0;

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

PARENT_ENV="$(mktemp -p "${XDG_RUNTIME_DIR:=/tmp}" gentoo-chroot-env.XXXXXXX)";
PARENT_SCRIPT='';
REBUILD='false';
CLEAN='false';
BOUND='';
OPTARG='';
OPTIND='';
while test "${#}" -gt 0; do
	case "$1" in
		-V|--version) printf '%s\n' "v$VERSION"; exit;;
		-v|--verbose)
			VERBOSE="$2"; shift;
		;;
		-p|--preserve-environment)
			export -p >> "$PARENT_ENV";
		;;
		-R) REBUILD='true';;
		-C) CLEAN='true';;
		-E)
			# NOTE: Use shell export logic to sanitize env output for reentry;
			# This will duplicate entries but that's more ideal than manually
			# coding this up.
			env -i "$2" "$SHELL" -c "export -p" >> "$PARENT_ENV"; shift;
		;;
		-B|--bind)
			bindmount "$2"; shift;
		;;
		--)
			shift; break
		;;
		-h|--help|*) print_help; exit;;
	esac;
	shift;
done;

if test -n "$1" && test "$(head -c 2 "$1")" = '#!'; then
	PARENT_SCRIPT="$1"; shift;
else
	# NOTE: clear the leftover params just so there's no unintended behavior
	shift "$#";
fi;

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
# XXX: The order here is important, as are the // marks on the child mounts.
#   the double //s fix a string splitting issue, and the mounts are in
#   order of last unmount. Normally you'd see these ordered of most importance
#   to boot / execute. But since this is a batch operation, we actually need to
#   focus on the post execution environment when these will be automatically
#   unmounted. They're unmounted in the reverse order they were mounted.
#guestmount --rbind /sys "//sys";
#guestmount --rbind /dev "//dev";
guestmount -t proc proc "//proc";
guestmount -o bind /dev "//dev";
guestmount -o bind /sys "//sys";
guestmount -o bind /dev/pts "//dev/pts";
guestmount -t tmpfs run "//run";
guestmount -t tmpfs tmp "//tmp";

# Ensure the network works properly. Basically coppied straight from proot
guestsync \
	/etc/resolv.conf \
	/etc/nsswitch.conf \
	/etc/host.conf \
	/etc/hosts \
	/etc/localtime \
	/etc/locale.gen;


GUEST_ENV="$(mktemp -p "$GENTOO_ROOT/tmp" transrootenv.XXXXXXX)";
GUEST_SCRIPT='';

cat "$PARENT_ENV" > "$GUEST_ENV";

if test -n "$PARENT_SCRIPT"; then
	GUEST_SCRIPT="$(mktemp -p "$GENTOO_ROOT/tmp" wrappedscript.XXXXXXX)";
	cat "$PARENT_SCRIPT" > "$GUEST_SCRIPT";
	chmod +x "$GUEST_SCRIPT";
	GUEST_SCRIPT="${GUEST_SCRIPT#"$GENTOO_ROOT"}";
fi;

#P='/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:/opt/bin';
chroot --userspec=0:0 "$GENTOO_ROOT" \
	/usr/bin/env TERM='linux' \
		/bin/bash -l << CHRENV
#\$(set +o);
#. ${GUEST_ENV#"$GENTOO_ROOT"};
rm -f ${GUEST_ENV#"$GENTOO_ROOT"};
if ! test -c $(printf "%q" "$(tty)"); then
	echo "error: failed to bind devpts into chroot";
	exit 1;
fi;

generate_locales(){
	# Damn writing this was a little nightmare lol
	NEW_LOCALES="\$(mktemp -p "\${XDG_RUNTIME_DIR:=/tmp}" "locale.gen-XXXX")";
	if eval dialog \
		--erase-on-exit \
		--separate-output \
		--output-fd 3 \
		--buildlist \
			"'Select locales to generate'" \
			0 0 "\$(wc -l < /usr/share/i18n/SUPPORTED)" \
			\$(while read -r line; do
				# WTF POSIX printf has builtin shell escape injection!?
				if grep -m 1 -qxFe "\$line" "/etc/locale.gen"; then
					status='on';
				else
					status='off';
				fi;
				printf "%q %q %q " "\$line" "\$line" "\$status";
			done </usr/share/i18n/SUPPORTED;) 3>"\$NEW_LOCALES";
	then
		mv -uf "\$NEW_LOCALES" /etc/locale.gen;
		locale-gen;
	else
		rm "\$NEW_LOCALES";
	fi;
}

activate_locale(){
	# Damn writing this was a little nightmare lol
	NEW_LOCALE="\$(mktemp -p "\${XDG_RUNTIME_DIR:=/tmp}" "active_locale-XXXX")";
	# IDK what the hell is up with the eselect devs adding whitespace to
	# "reusable" data. Most programs need to sanitized this, so WTF?
	CURRENT_LOCALE="\$(eselect --brief locale show | tr -d '[:space:]')";
	if eval dialog \
		--erase-on-exit \
		--output-fd 3 \
		--radiolist \
			"'Which available locale do you wish to acivate?'" \
			0 0 "\$(locale -a | wc -l)" \
			\$(locale -a | while read -r line; do
				if test "\$line" = "\$CURRENT_LOCALE"; then
					status='on';
				else
					status='off';
				fi;
				printf "%q %q %q " "\$line" "\$line" "\$status";
			done;) 3>"\$NEW_LOCALE";
	then
		read -r active_locale < "\$NEW_LOCALE";
		eselect locale set "\$active_locale";
	fi;

	rm "\$NEW_LOCALE";
}

# In case users need to do manual reconfiguration later.
export -f generate_locales;
export -f activate_locale;

if ! grep -m 1 -qPe "^[^#\\s]" "/etc/locale.gen"; then
	generate_locales;
fi;

if ! test -e /.initialized; then 
	activate_locale;
	. /etc/profile
	
	#emerge-webrsync
	
	emerge --oneshot app-portage/mirrorselect;
	
	# Automatically choose the top three best mirrors
	mirrorselect -s 3 -b 10;
	
	emerge --sync;
	touch /.initialized;
fi;

exec ${GUEST_SCRIPT:=/bin/bash} $* <$(printf "%q" "$(tty)");
CHRENV
