#!/bin/sh

# NOTE: This implementation of arrays uses the tmpfs filesystem to store
#   data due to how limiting the size constraints for environment variables
#   can be. This ensures high-volumes of data can be handled by the system
#   and guarantees working on small datasets won't produce any spurious errors 
#   which are hard to diagnose.


FLAG="$1";
case "$FLAG" in
	--*) :;;
	-*) 
		case "$FLAG" in
			) :;;
			) :;;
			) :;;
		esac;
	;;
esac;

mksharray()(
	COUNT='';
	STDIN='';
	while test "${#}" -gt 0; do
		case "$1" in
			-c|--count) COUNT="$2"; shift;;
			-) STDIN='true' break;;
			-h|--help|*) print_help; return 0;;
		esac;
		shift;
	done;
)

if command -v yes head >&-; then
	# This technique is about 2x faster than the pure posix sh method.
	__mksharray__(){ 
		printf "$(yes "%q" 2>&- | head -n "$#")\n" "$@";
	};
else
	__mksharray__(){
		for x in "$@"; do printf "%q\n" "$x"; done;
	};
fi;

sharray_insert(){}
#sharray_append(){}
sharray_get(){}
sharray_set(){}
unsharrayf(){
	# 50% faster;
	for array in "$@"; do
		eval set -- $array;
		for element in "$@"; do
			printf "%s\n" "$element";
		done;
	done;
}
unsharray(){
	while test "$#" -gt 0; do 
		{
			eval set -- $1;
			while test "$#" -gt 0; do
				printf "%s\n" "$1";
				shift;
			done;
		}
		shift;
	done;
}

#function levenshtein_distance(str1, str2)
#    local len1, len2 = #str1, #str2
#    local char1, char2, distance = {}, {}, {}
#    str1:gsub('.', function (c) table.insert(char1, c) end)
#    str2:gsub('.', function (c) table.insert(char2, c) end)
#    for i = 0, len1 do distance[i] = {} end
#    for i = 0, len1 do distance[i][0] = i end
#    for i = 0, len2 do distance[0][i] = i end
#    for i = 1, len1 do
#        for j = 1, len2 do
#            distance[i][j] = math.min(
#                distance[i-1][j  ] + 1,
#                distance[i  ][j-1] + 1,
#                distance[i-1][j-1] + (char1[i] == char2[j] and 0 or 1)
#                )
#        end
#    end
#    return distance[len1][len2]
#end

function levenshtein_distance(){
	strlen1=${#1}; strlen2="${#2}";
}
