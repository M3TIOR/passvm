#!/bin/sh
#
# I wrote this tool because I couldn't stand my template file looking like
# trash and not having proper syntax highlighting when putting it's contents
# in a heredoc...
#
# I swear sometimes I'm a menace to society.

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

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:=/tmp}";

__TEMPLATE_FILE='';
__SPEC='{{ENV}}';
__RIGHT='}}';
__LEFT='{{';
OPTARG='';
OPTIND='';
while getopts ":S:" flag; do
	case "$flag" in
		'S') 
			if test -z "$OPTARG"; then 
				perror "SPEC was specified, but is empty";
				exit 1;
			fi;

			__SPEC="$OPTARG";
			__RIGHT="${__SPEC##*ENV}";
			__LEFT="${__SPEC%%ENV"$__RIGHT"}";
			if test "$__RIGHT" = "$__SPEC"; then
				perror "invalid substitution SPEC, ENV not found in string '$__SPEC'";
				exit 1;
			elif test -z "$__RIGHT"; then
				perror "invalid subsitution SPEC, right delimeter is missing";
				exit 1;
			elif test -z "$__LEFT"; then
				perror "invalid subsitution SPEC, left delimeter is missing";
				exit 1;
			fi;
		;;
		'?')
			cat << EOF
USAGE: sst.sh [-S SPEC] TEMPLATE_FILE";
DESCRIPTION:
  Stupid Simple Template Script
  This script isn't very smart, all it does is look for an entry delimeter,
  and an exit delimeter. Whatever's between those two delimeters it considers
  a variable name. Each discovered template tag is replaced by the contents
  of the environment variable said name corresponds to. The result is dumped to
  stdout. For example:
    $ cat everywhere.template
    > {{HERE}} everywhere
    $ HERE='there' sst.sh everywhere.template
    > there everywhere
ARGUMENTS:
  -P > Don't process empty substitutions; leave them in the output file.
  -S > Template substitution specification; this tells sst.sh how to substitute
       variables into the template. Use ENV in your spec to represent the 
       environment variable name. Defaults to "{{ENV}}";
EOF
		exit;
		;;
	esac;
done;

if command -v sed 1>/dev/null 2>/dev/null; then
	substitute(){
		export KITTY_PUBLIC_KEY=; # monkeypatch for ENV breaker
		__script=$(mktemp -p "$XDG_RUNTIME_DIR");
		# Input to SED needs GOOOD sanitization; this is less than ideal; but at
		# least it works for the default delimeters
		__LEFT="$(echo "$__LEFT" | sed -Ee 's/([\{\}])/\\\\\1/g')";
		__RIGHT="$(echo "$__RIGHT" | sed -Ee 's/([\{\}])/\\\\\1/g')";
		env | sed -E \
			-e 's/\//\\\//g' \
			-e "s/(^.+)=(.*$)/s\/$__LEFT\1$__RIGHT\/\2\\//g" \
			> "$__script";
		sed -E -f "$__script" "$1";
		rm "$__script";
	}
else
	perror "missing sed; pure shell alternative not yet implemented";
	exit 1;
fi;

substitute "$1";
