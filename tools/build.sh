#!/bin/sh -ex
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

prompt_yn() {
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

phage()(
	perror(){
		test "$verbose" -ge 1 || return 0;
		# NOTE: alternative to LINENO because it's not POSIX compliant, and
		#   not very useful for debugging because it prints the CURRENT shell line
		#   which when using a function like this will always be the line within
		#   the function body rather than the parent scope's line. LN is a mnemonic
		#   shorthand which allows devs like me to manually enter line numbers
		#   with less finger strain. Additionally, it's recommended you use
		#   alias "perror='LN="$LINENO" perror'" if you do wish to use LINENO since
		#   this is known to work when LINENO is set.
		test -n "$LN" && printf '%s' "Error@$LN" >&2 || printf 'Error' >&2;
		printf "%s\n" ": $1" >&2;
		shift;
		while test "$#" -gt 0; do
			printf "\t%s\n" "$1" >&2;
			shift;
		done;
	};

	# HAHAHAH Subshell local functions!!!
	program_path(){
		# NOTE: for loop was introduced into POSIX standard for the shell
		#   at least in the 2018 standardization documents online. However 
		#   not all shells have implemented this feature so I'm not using it.
		#   This could be slightly more efficient.
		while test "$#" -gt 0; do
			if test "$verbose" -ge 4; then
				echo "searching for program '$1'" >&2;
			fi
			! command -v "$1" || return 0;
			shift;
		done;
		return 1;
	};

	remote_exists(){
		if rest_code="$(curl -Ls -X HEAD -w '%{http_code}' "$1")"; then :; else
			status="$?";
			case "$status" in
				18) status=0;; # Ignore partial content error.
				*) return $((status + 1));;
			esac;
		fi;

		case "$rest_code" in
			200) return 0;;
			[45][0-9][0-9]) return 1;;
		esac;
	};

	remote_enumerate_prefix(){
		urlpath="${1%/*}"; name="${1##*/}"; shift;

		while test "$#" -gt 0; do
			if test "$verbose" -ge 3; then
				echo "querying \"${urlpath}/${1}${name}\"" >&2;
			fi;
			! remote_exists "${urlpath}/${1}${name}" || break;
			shift;
		done;

		test "$#" -eq 0 && return 1;
		printf "%s" "${urlpath}${1}${name}";
	};

	remote_enumerate_suffix(){
		remote="$1"; shift;

		while test "$#" -gt 0; do
			if test "$verbose" -ge 3; then
				echo "querying \"${remote}${1}\"" >&2;
			fi;
			! remote_exists "${remote}${1}" || break;
			shift;
		done;

		test "$#" -eq 0 && return 1;
		printf "%s" "${remote}${1}";
	};

	remote_enumerate_sign_suffixes(){
		# shellcheck disable=SC2046,SC2086
		remote_enumerate_suffix "$1." $signature_extensions || \
		remote_enumerate_suffix "$1." $(alpha_to upper "$signature_extensions");
	};

	enumerate_hashsum(){
		remote_enumerate_suffix "$FILE_URL." $hash_formats ||
		remote_enumerate_suffix "$FILE_URL." $(alpha_to upper "$hash_formats") ||
		{
			test "$compression" != "cat" &&
			remote_enumerate_suffix "${FILE_URL%.*}";
		} ||
		remote_enumerate_prefix "${FILE_URL%/*}/sums" $hash_formats ||
		remote_enumerate_prefix "${FILE_URL%/*}/SUMS" $(alpha_to upper "$hash_formats");
	};

	enumerate_signature(){
		remote_enumerate_sign_suffixes "$FILE_URL" ||
		{ 
			test -n "$HASH_URL" &&
			remote_enumerate_sign_suffixes "$HASH_URL";
		} ||
		{
			test "$compression" != "cat" &&
			remote_enumerate_sign_suffixes "${FILE_URL%.*}";
		};
	};
	
	dtoh(){
		o=''; h=''; d="$1";
		while test "$d" -gt '0'; do
			case "$((d%16))" in
				0) h='0';; 1) h='1';; 2) h='2';; 3) h='3';; 4) h='4';;
				5) h='5';; 6) h='6';; 7) h='7';; 8) h='8';; 9) h='9';;
				10) h='A';; 11) h='B';; 12) h='C';; 13) h='D';; 14) h='E';; 15) h='F';;
			esac;
			o="$h$o";
			d="$((d>>4))";
		done;
		test -z "$o" && printf '0' || printf '%s' "$o";
	};

	# arithmetic status similar to *ax cpu logic.
	ax(){ test "$1" -ne 0; }; 

	alpha_to() {
		input="$2"; char=''; ord='';
		case "$1" in 
			upper)
			while test -n "$input"; do
				char="${input%"${input#?}"}";
				# shellcheck disable=SC2059
				case "$char" in
					[a-z]) ord="${CHARSET%"$char"*}"; printf "\x$(dtoh $((${#ord}-32)))";;
					*) printf '%s' "$char";;
				esac;
				input="${input#?}";
			done;;
			lower)
			while test -n "$input"; do
				char="${input%"${input#?}"}";
				# shellcheck disable=SC2059
				case "$char" in
					[A-Z]) ord="${CHARSET%"$char"*}"; printf "\x$(dtoh $((${#ord}+32)))";;
					*) printf '%s' "$char";;
				esac;
				input="${input#?}";
			done;;
			*)
			printf "Error: unrecognized alpha transformation '%s'!\n" "$1" >&2;
			return 1;;
		esac;
	};

	log_find_error(){
		case "$1" in
			0) :;;
			[6-8]) perror "cURL experienced an connection error! Are you online?";;
			4) perror "URL supplied was malformed, or empty!";;
			1) perror "the file requested doesn't exist on the server!";;
			*) perror "cURL threw an unexpected error code ($(($1 - 1)))!";;
		esac;
		return "$1";
	};

	string_in_file(){
		test -f "$2" || return 1;
		while read -r line; do
			test "${line#*"$1"}" = "$line" || return 0;
		done < "$2";
		return 1;
	};

	clean() {
		kill_jobs -s 'SIGKILL' "$sign_pid" "$hash_pid" "$decompress_pid";
		if $dirty; then
			echo "Notice: leaving temporary files in place; dirty." >&2;
		else
			rm -r "$temp";
		fi;
	};

	coerce_hash_format_from_file_heuristics() {
		# shellcheck disable=SC2034
		if "${HASH_PATH##*.}" != "$HASH_PATH"; then
			echo "${HASH_PATH##*.}";
		elif read -r x remainder < "$HASH_PATH"; then
			x="$(alpha_to lower "$x")";
			if "$hash_formats" != "${hash_formats#*"$(alpha_to lower "$x")"}"; then
				echo "$x";
				return 0;
			fi;
			case "${#x}" in
				10) echo 'crc';;
				32) echo 'md5';;
				40) echo 'sha1';;
				56) echo 'sha224';;
				# NOTE: sm3 has the same hash width as sha256 but it only exists within
				#   cksum and we currently require that so this is fine. It'll be
				#   caught by the above clause.
				64) echo 'sha256';;
				96) echo 'sha384';;
				# XXX: this could be either blake2 or sha512 but I'm using sha512
				#   since it seems to be more common through my own experience.
				128) echo 'sha512';;
				*) return 1;;
			esac;
		else
			return 1;
		fi;
	};

	signmeta_needs_update() {
		if test -f "$META_PATH";
			then contents="$(cat "$META_PATH")";
		else
			# always need update if we don't have the metafile already
			return 0;
		fi;
		# When we have signature or hashsum, and our file doesn't contain
		# either one, we need to update.
		{ 
			test -n "$SIGN_URL" && \
			test "$contents" = "${contents#*"$SIGN_URL"}";
		} || \
		{
			test -n "$HASH_URL" && \
			test "$contents" = "${contents#*"$HASH_URL"}";
		};
	}

	load_signmeta() {
		l=0; fp=;
		if ! test -f "$META_PATH"; then
			return 1;
		fi;
		while read -r line; do
			if test "$line" = "$FILE_URL"; then
				fp="$l";
			fi;
			if test "$line" = '###\/\/\/\/###'; then
				fp=;
			fi
			if test -z "$fp"; then
				continue;
			fi;
			case "$((l-fp))" in 
				0) :;;
				1) SIGN_URL="${SIGN_URL:="$line"}";;
				2) HASH_URL="${HASH_URL:="$line"}";;
			esac;
			l="$((l+1))";
		done < "$META_PATH";
	}
	
	write_signmeta() {
		printf "%s\n%s\n%s\n%s\n" \
			"$FILE_URL" \
			"$SIGN_URL" \
			"$HASH_URL" \
			"last updated: $(date)" \
			'###\/\/\/\/###';
	}

	save_signmeta() {
		# A little less readable but a single invocation!
		l=0;
		touch "$META_PATH~";
		if test -f "$META_PATH"; then
			while read -r line; do
				if test -z "$l"; then
					echo "$line" >> "$META_PATH~";
				fi;
				if test "$line" = "$FILE_URL"; then
					# Modify in place
					if test "$s" != "$SIGN_URL" || test "$h" != "$HASH_URL"; then
						write_signmeta "$FILE_URL" >> "$META_PATH~";
					fi;
					l='';
				else
					echo "$line" >> "$META_PATH~";
					l="$((l+1))";
				fi;
			done < "$META_PATH";
		fi;
		if test -n "$l"; then
			# Append to the end
			write_signmeta "$FILE_URL" >> "$META_PATH~";
		fi;
		cp -u "$META_PATH~" "$META_PATH";
		rm "$META_PATH~";
	}

	get_job_id(){
		job='';
		if test "$1" != "${1#%}"; then
			if jobs "$1" 2>/dev/null; then
				echo "$1";
				return 0;
			else
				return 1;
			fi;
		fi;
		jobs -l | while read -r line; do
			if test "$line" != "${line#*[[0-9]*]}"; then
				echo "$line" | IFS=" []" read -r x job x;
			fi;
			if test "$line" != "${line#*"$1"}"; then
				echo "%$job";
				return 0;
			fi;
		done;
		return 1;
	};

	wait_jobs(){
		print_failing_jid='false';
		sep='\x20'; # space
		#print_fail_pid='false';
		unset OPTARG;
		unset OPTIND;
		while getopts ":fh0" flag; do
			case "$flag" in
				f) print_failing_jid='true';;
				0) sep='\x00';;
				#F) print_fail_jid='true';;
				h|?)
					cat <<HELP_EOF >&2;
Usage: wait_jobs [-f0] %JOB|PID ...
Description:
	Wait for POSIX job specified by either a raw PID or POSIX job descriptor.
Arguments:
	-f  > print failing job IDs separated by spaces.
	-0  > use null delimeters instead of spaces on output.
HELP_EOF
			esac;
		done;
		shift "$((OPTIND - 1))";
		
		r=0;
		while test "$#" -gt 0; do
			if test -n "$1" && job="$(get_job_id "$1")"; then
				if wait "$job" 2>&-; then :; else
					r="$?";
					$print_fail_jid && printf "$job$sep";
				fi;
			fi;
			shift;
		done;
		return "$r";
	}

	kill_jobs(){
		signal='SIGTERM';
		unset OPTARG;
		unset OPTIND;
		while getopts ":s:h" flag; do
			case "$flag" in
				s) signal="$OPTARG";;
				#F) print_fail_jid='true';;
				h|?)
					cat <<HELP_EOF >&2;
Usage: kill_jobs [-s SIGNAL] %JOB|PID ...
Description:
	Kill a POSIX job specified by either a raw PID or POSIX job descriptor.
Arguments:
	-s  > send SIGNAL to each job.
HELP_EOF
			esac;
		done;
		shift "$((OPTIND - 1))";

		while test "$#" -gt 0; do
			if test -n "$1" && job="$(get_job_id "$1")"; then
				kill -s "$signal" "$job" 2>&-;
			fi;
			shift;
		done;
	};

	help(){
		cat << EOF
Usage: phage [-DEhdpukm] [-P EXTRACT_LIST] [-M META_PATH] [-S SIGNATURE_URL]
             [-H HASH_URL] FILE_URL
Description:";
  Securely downloads files from the web with GnuPG verification.
  Primarily targeting developer assets including archives and
  binaries. Currently supports Zip and GNU Tape Archives.
  Written to reduce nand-flash wear by using streams to reduce
  direct filesystem IO.
Arugments:
  -D  > Decompress the file if it's recognized as a supported archive type.
        Fails when unrecognized.
  -E  > Extract the file if it's a recongized archive format.
  -P  > When extracting, EXTRACT_LIST is a file containing a list
        of target file paths to extract from the archive, with
        one file path listed per line. (Not Yet Implemented)
  -d  > Leave working files behind; dirty. Useful for debugging.
  -p  > Allow plaintext transfer. ONLY use this option without
        the '-u' option in effect, as this will leave you w/o
        protection from MitM attacks. It's only appropriate to
        use '-pu' if the downloaded asset is a plaintext file which
        doesn't compile into a program or configure a programs.
        execution. USE AT YOUR OWN RISK.
  -u  > Permit download of unsigned binaries. For cases where
        developers have written software which doesn't author GPG
        signatures for verification on download. Removes protection
        from supply chain attacks.
  -k  > Keep containing archive after extraction. When used, will
        store the archive using it's remote filename in the current
        working directory prior to extraction and will leave it in
        place after the extraction has finished. If -E is not used,
        this option does nothing.
  -n  > No refetching! If the file is finishes downloading successfully,
        then this program will write it's URL into ./phaged and refuse to
        redownload it unless the URL is removed from it.
  -m  > Write the SIGNATURE and HASHSUM urls to a .signmeta after they've been
        enumerated. If the files are fetched again, and this option is enabled,
        the .signmeta will allow the reuse of the URLs without enumeration.
        this can save a ton of time with large projects where you may need to
        re-fetch assets and have the flexibility to leave the metafiles lying
        around as enumeration in the shell is extremely slow. If the
        -S or -H options are used, their values will override and update the
        .signmeta file.
	-M  > Use META_PATH file path to a metadata store for multiple files.
        Keeps the filesystem tidy! Also enables '-m' option.
        You may also set META_PATH as an environment variable prior to 
        execution and it will work with '-m' as well.
  -S  > Manually specify the signature URL if one exists.
  -H  > Manually specify the hashsum URL if one exists.
EOF
	};

	# XXX: First character is space because some shells will supress nulls even
	#   inside delimeter captured strings. What would have been null is a dup.
	#   This represents the ASCII charset for now. May need to improve upon this
	#   at a later date but for now it's functional.
	#   REQUIREMENT for alpha_to function!
	# NOTE: At least in the POSIX 2018 spec, ++ does indeed work. Unless I'm
	#   reading the docs wrong. I guess we'll have to wait and see if anyone
	#   has issues. I don't really care about super old shells for this.
	#   Not my target demographic.
	# shellcheck disable=SC3018,SC2059
	CHARSET=" $(i=0; while ax "$((i++ < 128))"; do printf "\x$(dtoh $i)"; done)";
	unset OPTARG;
	unset OPTIND;
	unset SIGN_URL;
	unset HASH_URL;
	compression='cat';
	# NOTE: hash formats are in order of most common to least common from my own
	#   experience & with highest (approximate) cryptographic strength first
	hash_formats="sha512 blake2b sha384 sha256 sm3 sha224 sha1 md5 crc";
	# NOTE: Taken from GnuPG's man page. + Linux archive wierd .sign garbage.
	signature_extensions="asc sig sign";

	verbose='3';
	decompress='false';
	extract='false';
	dirty='false';
	keep_archive='false';
	allow_plaintext='false';
	allow_unsigned='false';
	use_signmeta='false';
	no_refetching='false';
	while getopts ':DEhdpukqmnv:M:S:H:' flag; do 
		case "$flag" in
			D) decompress='true';;
			E) extract='true';;
			d) dirty='true';;
			p) allow_plaintext='true';;
			u) allow_unsigned='true';;
			k) keep_archive='true';;
			q) verbose=0;;
			n) no_refetching='true';;
			m) use_signmeta='true';;
			M) use_signmeta='true'; META_PATH="$OPTARG";;
			v) case "$OPTARG" in
				[0-5]) verbose="$OPTARG";;
				QUIET) verbose='0';;
				ERROR) verbose='1';;
				WARNING) verbose='2';;
				INFO) verbose='3';;
				DEBUG) verbose='4';;
				SILLY) verbose='5';;
				*)
					perror "unrecognized verbosity level $OPTARG! See -h for more info.";
					return 1;
				;;
			esac;;
			H) HASH_URL="$OPTARG";;
			S) SIGN_URL="$OPTARG";;
			h|?) help; return 1;;
		esac;
	done;
	shift "$((OPTIND - 1))";
	FILE_URL="$1";
	# URL path pruning
	# TODO: May have to edit this later if cURL doesn't output files
	#   with URL percent encoding sanitization in place. Slashes
	#   may polute the actual filename and break the code.
	FILE_PATH="${FILE_URL##*/}";
	META_PATH="${META_PATH:=$FILE_PATH.phage}";

	if ! program_path curl >&-; then
		perror "missing required binary executable cURL!";
		return 1;
	fi;

	status='0';
	protocol="${FILE_URL%%://*}";
	# NOTE: if we are using an insecure / plaintext protocol from the start
	#   try the upgraded e2e alternatives prior to using the less secure version.
	case "$protocol" in 
		http) protocol='https'; FILE_URL="https://${FILE_URL#*://}";;
	esac;
	# This is just more maintainable in case I do future upgrades here.
	if remote_exists "$FILE_URL"; then :; else status="$?";
		# TODO: maybe in the future expand this to support more protocols.
		#   For now we only need http & https since they're most common.
		#   Might just add more features in the C or Rust rewrite.
		case "$protocol" in
			https) protocol='http'; FILE_URL="http://${FILE_URL#*://}"; continue;;
			*) protocol='';;
		esac;
		if test -n "$protocol"; then
			remote_exists "$FILE_URL" || true;
			status="$?";
		fi;
		log_find_error "$status" || return "$?";
	fi;

	if test "$protocol" = "http" && ! $allow_plaintext; then
		test "$verbose" -lt 1 || \
			perror "file exists, but the server lacks ssl encryption!" \
				"If you must bypass this error, use the '-p' flag. It is unadvisable" \
				"to combine both the 'p' and 'u' flags, as this leaves you without" \
				"any protection from MitM attacks. It may be appropriate for raw text" \
				"however, use at your own risk.";
		return 1;
	fi;
	
	# THANKS: https://stackoverflow.com/a/32139879
	# Soft form suffix matching
	# NOTE: I double checked and this is actually 100% the same functionality.
	#   When reversing https://github.com/Distrotech/tar, which is itself a
	#   (maybe old) mirror of upstream git://git.savannah.gnu.org/tar.git, 
	#   if we follow the command line through tar's main file `tar.c`, we'll see
	#   that each of the command line options just stores the command name in a
	#   variable which is then later passed directly to `execlp` in `system.c`:
	#     /src/tar.c:1370    -> parse_opt (int key, char *arg, struct argp_s...
	#     /src/tar.c:1374    -> switch (key)
	#     /src/tar.c:1481    -> set_use_compress_program_option (BZIP2_PROGRAM);
	#     ||:1485 ||:1533 ||:1537 +++...
	#     /src/tar.c:936     -> set_use_compress_program_option (const char ...
	#     /src/tar.c:942     -> use_compress_program_option = string;
	#     /src/system.c:368  -> execlp (use_compress_program_option, use_com... 
	#   ||/src/system.c:386  -> execlp (use_compress_program_option, use_com...
	case "${1#"${1%".t"*}"}" in 
		.tar)                         compression='cat';      archive='tar';;
		.tar.xz|.txz)                 compression='xz';       archive='tar';;
		.tar.lzma|.tlz)               compression='lzma';     archive='tar';;
		.tar.zst|.tzst)               compression='zstd';     archive='tar';;
		.tar.gz|.t[ag]z)              compression='gzip';     archive='tar';;
		.tar.bz2|.t[bz][z2]|.tbz2)    compression='bzip2';    archive='tar';;
		.tar.Z|.tZ|.taZ)              compression='compress'; archive='tar';;
		.tar.lzo)                     compression='lzop';     archive='tar';;
		.tar.lz)                      compression='lzip';     archive='tar';;
	esac;

	case "${1#"${1%".zip"*}"}" in
		.zip)                         compression='cat';      archive='zip';;
		.zip.xz)                      compression='xz';       archive='zip';;
		.zip.lzma)                    compression='lzma';     archive='zip';;
		.zip.zst)                     compression='zstd';     archive='zip';;
		.zip.gz)                      compression='gzip';     archive='zip';;
		.zip.bz2)                     compression='bzip2';    archive='zip';;
		.zip.Z)                       compression='compress'; archive='zip';;
		.zip.lzo)                     compression='lzop';     archive='zip';;
		.zip.lz)                      compression='lzip';     archive='zip';;
	esac;

	if test -z "$compression"; then
		case "${1#"${1%"."*}"}" in
			.xz)                        compression='xz';       archive='';;
			.lzma)                      compression='lzma';     archive='';;
			.zst)                       compression='zstd';     archive='';;
			.gz)                        compression='gzip';     archive='';;
			.bz2)                       compression='bzip2';    archive='';;
			.Z)                         compression='compress'; archive='';;
			.lzo)                       compression='lzop';     archive='';;
			.lz)                        compression='lzip';     archive='';;
		esac;
	fi;

	if ! $decompress; then
		compression='cat';
	fi;

	if $no_refetching && string_in_file "$FILE_URL" "phaged"; then
		perror "file is already downloaded, won't refetch.";
		return 1;
	fi;

	if $extract && test -z "$archive"; then
		perror "cannot extract file, unsupported or unrecognized archive type!";
		return 1;
	fi;

	if ! command -v "$compression" >&-; then
		perror "unable to decompress file, missing '$compression' util!";
		return 1;
	fi;
	
	filename="${FILE_URL##*/}";
	if $use_signmeta && test -f "$META_PATH" && ! load_signmeta; then
		perror "failed to load signmeta for $FILE_URL, filename conflict?";
	fi;
	
	# NOTE: Compound if statement; subshell is only run when value is unset
	#   to begin with. This is handled in the shell without spawning a subprocess.
	#   it should be much faster than $(test -n ...);
	# shellcheck disable=SC2046,SC2086
	SIGN_URL="${SIGN_URL:="$(enumerate_signature)"}" || true;
	HASH_URL="${HASH_URL:="$(enumerate_hashsum)"}" || true; 
	if $use_signmeta && test -n "$HASH_URL$SIGN_URL" && signmeta_needs_update;
	then
		# If we have either the SIGNATURE or the HASHSUM
		# and we have signmeta enabled, write to the signmeta file in the CWD
		# only when writing would result in a change to the file.
		save_signmeta;
	fi;

	# NOTE: should always have cksum; it's mentioned in POSIX 2018 standard.
	#   but it's an OS util and not a shell utility which has undefined behavior.
	# TODO: maybe at a later date add support for falling back to direct sha*sum
	#   utilities if the system is missing cksum. BUT NOT RIGHT NOW
	hashprog="$(program_path cksum)";
	signprog="$(program_path gpg2 gpg)";
	hashpipe='/dev/null';
	signpipe='/dev/null';
	p_curl='';
	p_decompress='';
	
	# The grand protection clause
	if ! $allow_unsigned; then
		# NOTE: the enumeration portion is written so that if the asset does use a
		#   signed hashsum, both the signature and the hashsum will be missing when
		#   the hashsum can't be found.
		if test -z "$SIGN_URL"; then
			# TODO: Not all remote archives may have security standards like mine.
			#   This probably needs the option to be ignored for certain archives.
			perror "unable to locate signature for remote file.";
			return 1;
		elif test -z "$signprog"; then
			perror "unable to verify with signature, missing GnuPG!";
			return 1;
		# This still works even with the URL variants; or at least it should
		# except for in wierd host situations that require url query segments to
		# authorize the download of a hosted asset.
		elif test "${SIGN_URL#.*}" = "$HASH_URL" && test -z "$hashprog"; then
			perror "unable to verify with signed hashsum, missing 'cksum'!";
			return 1;
		fi;
	fi;

	# TODO: look up error codes for mktemp and do some proper error reporting.
	#   Need to look through the source code because the manual wasn't very
	#   helpfull!
	#     Thu Aug 24 03:48:09am
	#       Following up on this and it looks like I'm just not going to do
	#       any better than the following. The documentation was a pain and I'm
	#       too tired to do proper research + this is probably NBD anyway.
	# shellcheck disable=SC2030
	if ! temp="$(mktemp -dp "${XDG_RUNTIME_DIR:=/tmp}" "sage-fetch-XXXXXX")"; then
		perror "couldn't allocate temporary directory!" \
			"XDG runtime store may be full.";
		return 1;
	fi;

	# Ensure we clean up properly upon shutdown.
	# NOTE: unset PID storage variables so they're empty before clean in case
	#   we exit prior to them being set.
	unset sign_pid hash_pid decompress_pid
	trap 'clean; return 1;' EXIT SIGINT SIGKILL;

	if test -n "$HASH_URL"; then
		echo "Downloading hashsum: $HASH_URL";
		if ! { cd "$temp"; curl -\#LO "$HASH_URL"; }; then
			perror "hashsum failed to download; you may have lost internet.";
			return 1;
		fi;
	fi;

	if test -n "$SIGN_URL"; then
		echo "Downloading signature: $SIGN_URL";
		if ! { cd "$temp"; curl -\#LO "$SIGN_URL"; }; then
			perror "signature failed to download; you may have lost internet.";
			return 1;
		fi;
	fi;

	HASH_PATH="${HASH_URL##*/}";
	SIGN_PATH="${SIGN_URL##*/}";
	test -z "$SIGN_PATH" || SIGN_PATH="$temp/$SIGN_PATH";
	test -z "$HASH_PATH" || SIGN_PATH="$temp/$HASH_PATH";

	if test -z "$hashprog" || test -z "$HASH_PATH"; then
		hashprog='true';
	else
		# NOTE: suffix matching could break the decompression logic at the end
		#   of this routine, but since .t* matches are for all tar formats, which
		#   are the only decompressed archives currently supported, it should be
		#   fine.
		if string_in_file "$filename" "$HASH_PATH"; then
			hashpipe="$temp/$filename";
		elif string_in_file "${filename%.*}" "$HASH_PATH"; then
			hashpipe="$temp/${filename%.*}";
		else
			perror "hashsum file doesn't contain a hash for the downloaded file!";
			return 1;
		fi;
		# This is probably redundant if the signature detached from the $filename.
		# TODO: look into how GnuPG works and make sure it's safe to ignore this
		#   if we already have a primary detached signature.
		mknod "$hashpipe" p;
		sum_format="$(coerce_hash_format_from_file_heuristics)";
	fi;

	if test -z "$signprog" || test -z "$SIGN_PATH"; then
		signprog='true';
	else
		if test "$SIGN_PATH" = "${SIGN_PATH%.sig}"; then
			mv "$SIGN_PATH" "${SIGN_PATH%.*}.sig" || return 1;
			SIGN_PATH="${SIGN_PATH%.*}.sig";
		fi;

		signpipe="$temp/p_signature_validation";
		mknod "$signpipe" p;
	fi;

	{
		cd "$temp";
		$hashprog -a "${sum_format:=crc}" -c "$HASH_PATH" & hash_pid="$!";
		$signprog --verify "$SIGN_PATH" "$signpipe" & sign_pid="$!";
	};

	# This verifies any signed hashes; significantly less complicated
	# for me to write than what the Linux source archive has going on. :/
	if test -n "$HASH_PATH" && test "$HASH_PATH" = "${SIGN_PATH%.sig}"; then
		cat "$HASH_PATH" >> "$signpipe" &

		if ! wait_jobs "$sign_pid"; then
			perror "failed GPG hashsum verification for '$filename'!";
			return 1;
		fi;
		
		signpipe='/dev/null';
	fi;

	# What file is our signature expecting?
	if test "${filename}" = "${SIGN_PATH%.*}"; then
		p_curl="$p_curl $signpipe";
	elif test "${filename%.*}" = "${SIGN_PATH%.*}"; then
		p_decompress="$p_decompress $signpipe";
	fi;

	# What file is our hashsum expecting?
	if test -n "$HASH_PATH" && string_in_file "${filename}" "$HASH_PATH"; then
		p_curl="$p_curl $hashpipe";
	else
		p_decompress="$p_decompress $hashpipe";
	fi;

	# Add flags when we're decompressing
	if test "$compression" != "cat"; then
		compression="$compression -cd";
		# Remove compression artifact suffix.
		filename="${filename%.*}";
	fi;
	
	decompressed_pipe="$temp/p_decompressed";
	extract_from="$decompressed_pipe";
	mknod "$decompressed_pipe" p;

	# NOTE: if inpipes is used, uses parameter expansion to pipe to one or
	#   multiple FIFO pipe files.
	# shellcheck disable=SC2086
	{
		cd "$temp";
		echo "Downloading asset from URL: $FILE_URL";
		curl -# -L --raw "$FILE_URL" | \
			tee -pa $p_curl | \
			$compression | \
			tee -pa $p_decompress >> "$decompressed_pipe" & decompress_pid="$!";
	};

	if $keep_archive || ! $extract; then
		cat "$extract_from" > "$filename";
		extract_from="$filename";

		# NOTE: at the worst this should just be a single redundant wait.
		#   I don't think waiting for the same PID twice can cause problems.
		#   But we'll see IG.
		# NOTE: followup, yes, waiting for the same PID can be harmful I had to
		#   write a special function to wait in the way I want. Dammit.
		if ! wait_jobs "$hash_pid" "$sign_pid"; then
			perror "signature for file invalid!";
			if $keep_archive && test "$verbose" -lt 1; then
				printf "\t%s\n" "Refusing to extract archive." >&2;
			fi;
			return 1;
		fi;
	elif test "$archive" = 'zip'; then
		# NOTE: Zip files have a footer that must be used to locate all
		#   contained contents. Without it the zipfile extraction may be
		#   corrupt and will be at least malformed. So we must write it to
		#   the temporary folder; which hopefully sits in a Linux tmpfs.
		#   The tmpfs is a ram filesystem with hardware backing when files
		#   get too big for memory. So at the least it should still help
		#   reduce flash memory sector writes when the user has enough RAM.
		cat "$decompressed_pipe" > "$temp/zipfile";
		extract_from="$temp/zipfile";
	fi;

	if $extract; then
		case "$archive" in 
			tar) extract_bin='tar --overwrite -xf';;
			zip) extract_bin='zip -u';;
			*) extract_bin='true';;
		esac;
	fi;

	# TODO: use functional job control! This breaks, we need it not to.
	if ! { cd "$temp"; $extract_bin "$extract_from"; }; then
		perror "failed extraction of archive, archive must be malformed!";
		return 1;
	elif wait_jobs "$hash_pid" "$sign_pid"; then
		perror "signature for file invalid!" \
			"It is advised you discard the extracted contents.";
		return 1;
	elif wait_jobs "$decompress_pid"; then
		perror "cURL failed while downloading file!"
			"Contents may be incomplete, please retry the query.";
		return 1;
	fi;

	if $no_refetching && ! string_in_file "$FILE_URL" "phaged"; then
		echo "$FILE_URL" >> "phaged";
	fi;
);

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
#   https://www.linuxfromscratch.org/blfs/view/svn/postlfs/initramfs.html
#

KERNEL_URL='https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.4.12.tar.xz';
BUSYBOX_URL='https://www.busybox.net/downloads/busybox-1.36.1.tar.bz2';
BASH_URL='https://ftp.gnu.org/gnu/bash/bash-5.2.15.tar.gz';
PASS_URL='https://git.zx2c4.com/password-store/snapshot/password-store-1.7.4.tar.xz';
#GNUPG_URL='';
#CRYPSETUP_URL='https://www.kernel.org/pub/linux/utils/cryptsetup/v2.6/cryptsetup-2.6.1.tar.xz';
#WORKING_DIR="$PWD";



KERNEL_PARAMS="mitigations=off quiet";
XDG_DATA_HOME="${XDG_DATA_HOME:=$HOME/.local/share}";
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:=$HOME/.config}";
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:=/tmp}";
PROGRAM="$(readlink -nf "$0")";
PROGRAM_DIR="$(dirname "$PROGRAM")";
SOURCE_DIR="$(readlink -nf "$PROGRAM_DIR/..")";

cd "$PROGRAM_DIR";

# NOTE: This doesn't have to be perfect immediately and I should just do
#   what I can ASAP since that's the goal rn but eventually I'd like to
#   migrate to using my own C written `pass` alternative / rewrite.
#   It'd certainly eliminate a large source of bloat from this project.
#   Specifically the BASH blob is 10M like what the hell? Initramfs load times
#   gonna make me sad.

# Dependency list
# `busybox`
# `pass` -\
#         `bash`
#         `gnupg2`
#         `tree`
#         GNU `getopt`
#         Technically requires git but it looks like it can function without it.
#         might be a little complainy though.
# `cryptsetup`

# Parse CLI
while getopts "sckK:v" flag; do
	case "$flag" in
		's') mkdir -p .buildfiles;;
		'k') SOURCES_URL="$OPTARG";;
		'*')
			cat << EOF
USAGE: build.sh [-svh] [-k ARCHIVE]";
DESCRIPTION:";
  Compiles the passvm kernel and initramfs.";
ARGUMENTS:";
  -H > Download build assets to ./.buildfiles instead of using";
       the tmpfs at XDG_RUNTIME_HOME. Useful if you're frequently";
       building or debugging.";
  -n > Don't clean the build directory when finished. Usefull";
       when paired with -H";
  -K > Prior to fetching assets, automatically fetch all relevant";
       PGP keys for build asset distributors to verify signatures.";
  -k > Specify an alternative URL or PATH to the kernel sources";
       archive you want to use. By default, kernel sources are";
       fetched from the latest Kernel Archives stable release.";
";
EOF
		;;
	esac;
	shift;
done;


if test -d ".buildfiles"; then
	BUILD_DIR="$SOURCE_DIR/.buildfiles";
else
	BUILD_DIR="$(mktemp -d -p "$XDG_RUNTIME_DIR" "passvm_build-XXXXXX")";
fi;

# Before build, ensure we at least import the keys form kernel.org.
# NOTE: unnecessary, I was doing this while bug hunting and it turns out
#   I was decompressing an archive wrong. :/
#git clone https://git.kernel.org/pub/scm/docs/kernel/pgpkeys.git


grep -vEe '^\s*#' <<-PGP_KEYS | xargs gpg --locate-keys;
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

# TODO: properly validate Gentoo stuff
#   https://www.gentoo.org/downloads/signatures/

if test "$?" -ne 0; then
	printf "%s\n\t%s\n\t%s\n\t%s\n" \
		"Warning: Failed to import PGP signatures for at least one of the" \
		"\tdependency maintainers. You may choose to continue, but this" \
		"\tmay erode the security of your password manager as it reduces" \
		"\tthe build's protection against supply chain attacks." >&2;


	if ! prompt_yn n "Would you like to continue anyway?"; then
		exit 1;
	fi;
fi;

cd "$BUILD_DIR";
mkdir initramfs;

# NOTE: Until phage is working, I'll just do things manually to speed 
#   up the process of writing this.
#export META_PATH="phages";
#phage -m -n "$KRNLSRC_URL";

curl -#LO "$PASS_URL" "${PASS_URL#.*}.sig";
#gpg --verify bash-5.2.15.tar.gz.sig bash-5.2.15.tar.gz;
tar -xzvf password-store-1.7.4.tar.gz;

curl -#LO "$BUSYBOX_URL" "${BUSYBOX_URL#.*}.sig";
gpg --verify busybox-1.36.1.tar.bz2.sig busybox-1.36.1.tar.bz2;
tar -xjvf busybox-1.36.1.tar.bz2;

curl -#LO "$KERNEL_URL" "${KERNEL_URL#.*}.sign";
xz -d ${KERNEL_URL%%*/};
gpg --verify linux-6.4.12.tar.sign linux-6.4.12.tar;
tar -xvf linux-6.4.12.tar;

{
	# Compile kernel headers; this is required before using gentoo to build.
	cd 'linux-6.4.12';
	cp "$SOURCE_DIR"/assets/linux-6.4.12-config .config;
	make -e headers_install;
}


# List of required utilities for running the bash version of pass:
#  bash: local, source, [for((c-like))], .{a,b} -> .a .b (brace exp),
#        =~ (regex expansion),
#  external: gpg2, qrencode, grep
#  coreutils: 
#    provided by Busybox applets (some are POSIX and will be duped):
#       mv, rm, cp, tr, ls, tty, cat, mktemp, mkdir, shred, base64, dirname,
#       env, echo, printf, head, tail, sleep, which, sed, grep, pkill,
#       getopt (-l),
#       find (-type -exec -L -path -prune -o -print0 -iname)
#
#  POSIX: while, export, unset, read, exit, echo, return, for x in, sleep,
#         trap, exec, printf, set, eval, shift, break, case
#
# NOTE: needs /dev/shm to function optimally; learn how to make this work.
#       needs /dev/urandom to work as well. learn how to make this work as well.
#       this doesn't include utils from alt platforms; may need to adjust later.
#
# Initramfs bootstrapping utility dependencies:
#  sulogin, 
{
	# Build Busybox
	# TODO: finish manually creating busybox-1.36.1-config!
	# NOTE: Busybox provides httpd as a tiny http file host. This may come in
	#   handy later when I extend the API for pass to work over the network.
	# NOTE: Busybox PROVIDES NETCAT WHOAAAAAAAAAAA?!?! This means I don't have to
	#   separately compile it for communicating using direct ports over the lan.
	#   So my script should be slightly easier to flesh out!!!
	# TODO: I left modprobe and other linux module utilities enabled inside the
	#   VM when building busybox, but we could disable them to save some space
	#   after I confirm what modules the VM absolutely requires to run and what
	#   can be pruned off. Additionally, I left dmesg and less on for 
	#   debugging purposes.
	#   I also left ifconfig and route on as fallbacks to iproute2 even though
	#   I know iproute2 exists. After I get this working with iproute2, I'll
	#   disable that to save some space. It has a worse UI anyway.
	#   left top and sysctl on for debugging.
	cd 'busybox-1.36.1';
	cp "$SOURCE_DIR"/assets/busybox-1.36.1-config .config;
	make busybox;
}

{
	#echo 'emerge --sync; exit;' | "$PROGRAM_DIR/gentoo-chroot.sh";
	# Build more complicated binaries using gentoo build system.
	cat < "$SOURCE_DIR/assets/gentoo-shell-build-passvm" | \
		"$PROGRAM_DIR/gentoo-chroot.sh" \
			-B "$BUILD_DIR/linux-6.4.12:/mnt/kernel" \
			-B "$BUILD_DIR/build-staging:/mnt/build";
}

{
	# Compile kernel headers; this is required before using gentoo to build.
	cd 'linux-6.4.12';

	BUSYBOX_SRC="$(readlink -fn $(pwd)/../busybox-1.36.1)" \
	BUILD_STAGING="$(readlink -fn $(pwd)/../build-staging)" \
	PASSVM_RAMFS="$(readlink -fn $(pwd)/../../src/initramfs)" \
		"$SOURCE_DIR/tools/st.sh" "$SOURCE_DIR/assets/initramfs.cpio.template" > \
			passvm.cpio.cfg;

	# Create initramfs as regular user
	./usr/gen_initramfs.sh -o passvm.cpio ./passvm.cpio.cfg;

	# Build the kernel with builtin initramfs
	make;
}
