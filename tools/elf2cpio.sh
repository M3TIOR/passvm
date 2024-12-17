#!/bin/sh -ex

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

args2lines(){
	for arg in "$@"; do
	#while test "$#" -gt 0; do
		echo "$arg";
	done;
}

# TODO: figure out recursive handling of dependencies
elf2sodeps(){
	SYMBOL='([a-z0-9\/\._+-]+)';
	ADDRESS='\(0x[0-9a-f]+\)';
	arghash="$(printf '%s' "$@" | cksum -a md5 | tail -c 33 | head -c 1)"; 
	queue="$(mktemp -p "${XDG_RUNTIME_DIR:=/tmp}" "sodeps${arghash}XXXXX")";
	exec 3<>"$queue";
	
	# First pass removes executables from the tree
	for arg in "$@"; do
		ld.so --list "$arg" \
			| sed -E \
				-e "s/[ \t]+$SYMBOL (=> (ld.so|$SYMBOL) )?$ADDRESS/\4/gi" \
				-e '/^$/d';
	done >> "$queue";

	while read -r line; do
		#readelf -d "$1" \
		#	| grep -e "(NEEDED)" \
		#	| sed -Ee 's/ ?0x0+1 \(NEEDED\) +Shared library: \[(.*)\]/\1/g';
		ld.so --list "$line" \
			| sed -E \
				-e "s/[ \t]+$SYMBOL (=> (ld.so|$SYMBOL) )?$ADDRESS/\4/gi" \
				-e '/^$/d';
	done <&3 >>"$queue";
	
	cat "$queue" | sort -u | xargs readlink -f;
	
	exec 3>&-;
	rm "$queue"
}

sodep2cpio(){
	while read -r file; do
		filename="$(basename "$file")";
		printf "file %s %s    %s %s %s\n" \
			"${CPIO_PREFIX}${filename}" \
			"${HOST_PREFIX}${file}" \
			"$CPIO_MODE" \
			"$CPIO_UID" \
			"$CPIO_GID";
		
		IFS='.' read -r library so major minor patch << HATEHEREDOCS
$filename
HATEHEREDOCS
		if $CPIO_SEMVER; then
			if test "$major" -gt 0 && test "$library.so.$major" != "$filename"; then
				printf "slink %s %s   %s %s %s\n" \
					"${CPIO_PREFIX}${library}.so.${major}" \
					"${CPIO_PREFIX}${filename}" \
					"$CPIO_MODE" \
					"$CPIO_UID" \
					"$CPIO_GID";
			fi;
			printf "slink %s %s   %s %s %s\n" \
				"${CPIO_PREFIX}${library}.so" \
				"${CPIO_PREFIX}${filename}" \
				"$CPIO_MODE" \
				"$CPIO_UID" \
				"$CPIO_GID";
		fi;
	done;
}

fakechroot(){
	# Recompose the command wrapped in unshare when using an alternate root.
	unshare -UrR "$ROOT" /bin/sh -s $(set +o | sed -Ee 's/set (.+)/\1/') -- \
		$(if $CPIO_SEMVER; then echo "-S"; fi;) \
		-l "$CPIO_PREFIX" \
		-r "$HOST_PREFIX" \
		-i "$CPIO_UID:$CPIO_GID" \
		-m "$CPIO_MODE" \
		"$FILE" << EOF
export __ISFAKECHROOT='true';
. /etc/profile;
$(cat "$0")
EOF
}

help(){
	:;
}

CPIO_PREFIX='';
CPIO_UID='0';
CPIO_GID='0';
CPIO_MODE='755';
CPIO_SEMVER='false';
HOST_PREFIX='';
ROOT='';
EXCLUSIVE='false';
WITHINCONFIG="${__ISFAKECHROOT:=false}";
while test "$#" -gt 0; do
	case "$1" in
		'') :;; # suppress empty entries.
		'-l') ;& '--cpio-prefix') CPIO_PREFIX="$2"; shift;;
		'-r') ;& '--host-prefix') HOST_PREFIX="$2"; shift;;
		'-m') ;& '--mode') CPIO_MODE="$2"; shift;;
		'-x') ;& '--exclusive') EXCLUSIVE='true';;
		'-i') ;& '--owner') CPIO_UID="${2%:*}"; CPIO_GID="${2#*:}"; shift;;
		'-S') ;& '--add-semver-symlinks') CPIO_SEMVER='true';;
		'-R') ;& '--root') ROOT="$2"; shift;;
		'-') if test "$1" = '-'; then break; fi;;
		'-h') ;& '--help') ;& -*) help; exit 0;;
		*) break;;
	esac;
	shift;
done;

if test -z "$1"; then
	perror "failed to supply FILE";
	exit 1;
elif test "$1" = '-'; then
	:;
elif ! test -e "$1"; then
	perror "file $1 doesn't exist";
	exit 1;
fi;

FILE="$1";
CPIO_UID="${CPIO_UID:=0}";
CPIO_GID="${CPIO_GID:=0}";

if test "$FILE" = '-'; then
	# read from stdin
	iself='false';
	FILE='stdin'; # For logging
	exec 3<&0;
elif test -d "$FILE" -o -c "$FILE" -o -b "$FILE" -o -S "$FILE"; then
	perror "$FILE is an unusable filetype!";
	exit 1;
else
	iself="$(readelf -h "$FILE" 2>&- 1>&- && echo 'true' || echo 'false')";
	exec 3<"$FILE";
	
	if ! $iself; then
		read -r firstline < "$FILE";
		# When we have a shebang
		if "${firstline#\#!}" != "${firstline}"; then
			perror "$FILE is a script, not an ELF or cpio file!";
			exit 1;
		fi;
	fi;

	# resolve symlinks.
	FILE="$(readlink -fn "$FILE")";
fi;

# Usage:
# 	./usr/gen_init_cpio [-t <timestamp>] [-c] <cpio_list>
# 
# <cpio_list> is a file containing newline separated entries that
# describe the files to be included in the initramfs archive:
# 
# # a comment
# file <name> <location> <mode> <uid> <gid> [<hard links>]
# dir <name> <mode> <uid> <gid>
# nod <name> <mode> <uid> <gid> <dev_type> <maj> <min>
# slink <name> <target> <mode> <uid> <gid>
# pipe <name> <mode> <uid> <gid>
# sock <name> <mode> <uid> <gid>
#
# <name>       name of the file/dir/nod/etc in the archive
# <location>   location of the file in the current filesystem
#              expands shell variables quoted with ${}
# <target>     link target
# <mode>       mode/permissions of the file
# <uid>        user id (0=root)
# <gid>        group id (0=root)
# <dev_type>   device type (b=block, c=character)
# <maj>        major number of nod
# <min>        minor number of nod
# <hard links> space separated list of other links to file

if ! $iself && $WITHINCONFIG; then
	:; # skip files that aren't elf files within configs
elif ! $iself; then
	while read -r line; do
		# Remove comments
		line="${line%\#*}";

		# Skip empty lines
		if test -z "$line"; then continue; fi;

		set -- $line;
		
		if ! $EXCLUSIVE; then
			echo "$line"; 
		fi;

		case "$1" in
			'file') shift;;
			# no-op / ignore
			'slink'|'nod'|'dir'|'pipe'|'sock')
				continue
			;;
			*)
				perror "malformed CPIO config entry in $FILE at $line";
				exit 1;
			;;
		esac;
		
		cpio_path="$1";
		host_path="$2";
		mode="$3";
		uid="$4";
		gid="$5";
		hard_links="$*";

		FILE="$host_path";
		if test -n "$ROOT"; then
			FILE="${FILE#"$(readlink -nf "$ROOT")"}";
			fakechroot;
		else
			elf2sodeps "$FILE" | sodep2cpio;
		fi;
	done <&3 | sort -u;
elif test -n "$ROOT"; then
	fakechroot;
else
	elf2sodeps "$FILE" | sodep2cpio | sort -u;
fi;
