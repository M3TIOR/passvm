#!/bin/sh -e
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
while getopts ":" flag; do
	case "$flag" in
		'?')
			cat << EOF
USAGE: mustache.sh TEMPLATE_FILE";
DESCRIPTION:
  Mustache.js POSIX Shell substitute.
  This script isn't very smart, all it does is look for an entry delimeter,
  and an exit delimeter. Whatever's between those two delimeters it considers
  a variable name. Each discovered template tag is replaced by the contents
  of the environment variable said name corresponds to. The result is dumped to
  stdout. For example:
    $ cat everywhere.template
    > {{env.HERE}} everywhere
    $ HERE='there' mustache.sh everywhere.template
    > there everywhere
ARGUMENTS:
  -P > Don't process empty substitutions; leave them in the output file.
EOF
		exit;
		;;
	esac;
done;

if command -v sed 1>/dev/null 2>/dev/null; then
	# NOTE: Very finicky! NO TOUCHY!!!
	posix_export2mustache_sed_script(){
		flag='-[a-zA-Z0-9]+';
		param='[^\n\t\r ]*';
		name='[_a-zA-Z][_a-zA-Z0-9]*';
		value='\$?["'\''](.*)["'\'']';
		replacement='s\/\\\{\\\{env\\.\2\\\}\\\}\/\3\/g';
		sed -E \
			-e "s/\\//\\\\\\//g;" \
			-e "s/export ?($flag ?$param)* ($name)=$value/$replacement;/;";
	}

	substitute(){
		sed -Ee "$(export -p | posix_export2mustache_sed_script | tr -d '\n')" "$1";
	}
else
	perror "missing sed; pure shell alternative not yet implemented";
	exit 1;
fi;

substitute "$1";
