#!/bin/sh -e
# @file - passvm.sh
# @brief - virtualized password manager passthrough. 

_perror(){
	test "${verbose:=1}" -ge 1 || return 0;
	test -n "$LN" && printf '%s' "Error@$LN" >&2 || printf 'Error' >&2;
	printf "%s\n" ": $1" >&2;
	shift;
	while test "$#" -gt 0; do
		printf "\t%s\n" "$1" >&2;
		shift;
	done;
};

# XXX: Eazy hack on non-posix systems which support $LINENO for debugging.
alias perror='LN="$LINENO"; _perror';

require(){
	stack="$*";
	while command -v "$1" >&-; do shift; done;
	if test "$#" -gt 0; then
		# shellcheck disable=2086
		set $stack; # reset stack.
			perror "unable to locate a required binary in your PATH!";
		while test "$#" -gt 0; do
			printf "%s ->\x20" "$1";
			command -v "$1" || printf "missing\n";
			shift;
		done;
		exit 1;
	fi;
};

optional(){
	stack="$*";
	while command -v "$1" >&-; do shift; done;
	if test "$#" -gt 0; then
		# shellcheck disable=2086
		set $stack; # reset stack.
		printf "Warning: Unable to locate an optional binary in your PATH.\n" >&2;
		printf "\t%s\n" "Might terminate early." >&2;
		while test "$#" -gt 0; do
			printf "%s ->\x20" "$1";
			command -v "$1" || printf "missing\n";
			shift;
		done;
	fi;
};

prompt_yn(){
	case "$1" in
		[0yY]) default="Yn";;
		[1nN]) default="Ny";;
		*)
			printf 'Error: Prompt recieved invalid default argument.\n' >&2;
			exit 2;;
	esac;

	if test -n "$NOPROMPT"; then
		answer="$1";
	else
		while printf "%s" "$2 [$default]:" && read -r answer; do
			case "$answer" in
				[yY]*|[nN]*) break;;
				*) printf 'Invalid response, please answer Yes or No.\n';;
			esac;
		done;
	fi;

	case "$answer" in
		[0yY]*) return 0;;
		[1nN]*) return 1;;
	esac;
};

help(){
	:;
}

################################################################################
# MAIN
######

require curl git;
optional tar unzip;

# PIVOT: Building kernel and initramfs from scratch because TinyCore is
#   unmaintained and a dying ecosystem. I can get the image much smaller
#   by custom compiling it anyway. It's just a little more annoying to
#   put together.
#

# HELPFUL URLS:
#   https://wiki.gentoo.org/wiki/Initramfs_-_make_your_own#
#   what I can ASAP since that's the goal rn but eventually I'd like to
#   migrate to using my own C written `pass` alternative / rewrite.
#   It'd certainly eliminate a large source of bloat from this project.
#   Specifically the BASH blob is 10M like what the hell? Initramfs load times
#   gonna make me sad.

PROGRAM="$(readlink -nf "$0")";
PROGRAM_DIR="$(dirname "$PROGRAM")";
SOURCE_DIR="$(readlink -nf "$PROGRAM_DIR/..")";
KERNEL_URL='https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.4.12.tar.xz';
BUSYBOX_URL='https://www.busybox.net/downloads/busybox-1.36.1.tar.bz2';
BASH_URL='https://ftp.gnu.org/gnu/bash/bash-5.2.15.tar.gz';
PASS_URL='https://git.zx2c4.com/password-store/snapshot/password-store-1.7.4.tar.xz';

# Parse CLI
USE_TMPFS='false';
CLEAN='false';
while test "$#" -gt 0; do
	case "$1" in
		'-k'|'--kernel') KERNEL_URL="$2"; shift;;
		'-R'|'--use-tmpfs') USE_TMPFS='true';;
		'-c'|'--clean') CLEAN='true';;
		'-h'|'--help') help; exit 0;;
		'--') shift; break;;
		*) perror "unrecognized argument flag! $1"; exit 1;;
	esac;
	shift;
done;

cd "$SOURCE_DIR";

if $CLEAN; then
	rm -rf .buildfiles-nonvolatilebackup;
	rm -rf .buildfiles;
fi;

if $USE_TMPFS; then
	if test -d ".buildfiles"; then
		mv ".buildfiles" ".buildfiles-nonvolatilebackup";
	elif test -h ".buildfiles" && ! ; then
		BUILD_DIR="$(readlink -fn ".buildfiles")";
		if ! test -d "$BUILD_DIR"; then
			BUILD_DIR='';
			rm ".buildfiles";
		fi;
	fi;

	if test -z "$BUILD_DIR"; then
		BUILD_DIR="$(mktemp -d -p "$XDG_RUNTIME_DIR" "passvm_build-XXXXXX")";
		ln -sr -T "$BUILD_DIR" .buildfiles;
	fi;
else
	if test -h ".buildfiles"; then
		BUILD_DIR="$(readlink -fn ".buildfiles")";
		if test -d "$BUILD_DIR"; then
			rm -rf "$BUILD_DIR";
			rm ".buildfiles";
		fi;
	fi;
	if test -d ".buildfiles-nonvolatilebackup"; then
		mv ".buildfiles-nonvolatilebackup" ".buildfiles";
	fi;
	
	BUILD_DIR="$SOURCE_DIR/.buildfiles";
	mkdir -p "$BUILD_DIR";
fi;

# Before build, ensure we at least import the keys form kernel.org.
# NOTE: unnecessary, I was doing this while bug hunting and it turns out
#   I was decompressing an archive wrong. :/
#git clone https://git.kernel.org/pub/scm/docs/kernel/pgpkeys.git


grep -vEe '^\s*#' <<PGP_KEYS | xargs gpg --locate-keys;
	# A list of all the different maintainer's emails whom we should
	# verify the build files' signatures with.

	# Kernel maintainers
	torvalds@kernel.org
	gregkh@kernel.org

	# Busybox maintainers
	vda.linux@googlemail.com

	# GnuPG maintainers (https://gnupg.org/signature_key.html)
	#Andre Heinecke (Release Signing Key)
	#Werner Koch (dist signing 2020)
	#Niibe Yutaka (GnuPG Release Key)
	#GnuPG.com (Release Signing Key 2021)
	
	# Bash maintainers
	#chet@cwru.edu

	# Cryptsetup maintainers
	#Milan Broz <gmazyland@gmail.com>

	# util-linux maintainers
	#Karel Zak <kzak@redhat.com>

	# pass Password Store (couldn't find)
	# TODO: find this!!!!
PGP_KEYS

if test "$?" -ne 0; then
	perror \
		"Failed to import PGP signatures for at least one of the" \
		"dependency maintainers. You may choose to continue, but this" \
		"may erode the security of your password manager as it reduces" \
		"the build's protection against supply chain attacks.";


	if ! prompt_yn n "Would you like to continue anyway?"; then
		exit 1;
	fi;
fi;

cd "$BUILD_DIR";

# NOTE: Until phage is working, I'll just do things manually to speed 
#   up the process of writing this.
#export META_PATH="phages";
#phage -m -n "$KRNLSRC_URL";

#curl -#LO "$PASS_URL" "${PASS_URL#.*}.sig";
#gpg --verify bash-5.2.15.tar.gz.sig bash-5.2.15.tar.gz;

if test "$?" -ne 0; then
	perror \
		"Failed to import PGP signatures for at least one of the" \
		"dependency maintainers. You may choose to continue, but this" \
		"may erode the security of your password manager as it reduces" \
		"the build's protection against supply chain attacks.";


	if ! prompt_yn n "Would you like to continue anyway?"; then
		exit 1;
	fi;
fi;

cd "$BUILD_DIR";

# NOTE: Until phage is working, I'll just do things manually to speed 
#   up the process of writing this.
#export META_PATH="phages";
#phage -m -n "$KRNLSRC_URL";

#curl -#LO "$PASS_URL" "${PASS_URL#.*}.sig";
#gpg --verify bash-5.2.15.tar.gz.sig bash-5.2.15.tar.gz;
#tar -xzvf password-store-1.7.4.tar.gz;

if ! test -e "busybox-1.36.1/.unpacked"; then
	curl -#LO "$BUSYBOX_URL";
	curl -#LO "${BUSYBOX_URL#.*}.sig";
	gpg --verify busybox-1.36.1.tar.bz2.sig busybox-1.36.1.tar.bz2;
	tar -xjvf busybox-1.36.1.tar.bz2;
	rm busybox-1.36.1.tar.bz2;
	touch busybox-1.36.1/.unpacked;
fi;

if ! test -e "linux-6.4.12/.unpacked"; then
	curl -#LO "$KERNEL_URL";
	curl -#LO "${KERNEL_URL%.*}.sign";
	xz -d ${KERNEL_URL##*/};
	gpg --verify linux-6.4.12.tar.sign linux-6.4.12.tar;
	tar -xvf linux-6.4.12.tar;
	rm linux-6.4.12.tar;
	touch linux-6.4.12/.unpacked;
fi;

{
	# Build basically everything inside Gentoo because we need to make sure
	# all dynamic linking targets are linked properly and it's dependency
	# management and configuratbility are just granular and robust enough.
	"$PROGRAM_DIR/gentoo-chroot.sh" \
		-B "$BUILD_DIR/linux-6.4.12:/mnt/kernel" \
		-B "$BUILD_DIR/busybox-1.36.1:/mnt/busybox" \
		-B "$SOURCE_DIR:/mnt/passvm" \
		-- "$SOURCE_DIR/tools/gentoo-build.sh" $*;
}
