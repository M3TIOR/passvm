#!/bin/sh
# TODO: don't forget to:
#   emerge --sync; # first and foremost

# NOTE:
#   KERNEL_DIR must point to a valid kernel source tree for some packages
#   to be built. Without it, they will attempt to link against the running
#   kernel, use erronious headers, and result in a broken initramfs.
# XXX: Required kernel options:
#   * CONFIG_SYSVIPC <- lvm2 <- cryptsetup
#   * CONFIG_DM_CRYPT <- cryptsetup
export GENTOO_DIR="/";
export KERNEL_DIR="/mnt/kernel"; # OR ln -s /mnt/kernel /usr/src/linux;
export BUSYBOX_DIR="/mnt/busybox"; 
export PASSVM_DIR="/mnt/passvm";
export PASSVM_RAMFS="$PASSVM_DIR/src/ramfs";

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


cd "$PASSVM_DIR/.buildfiles";

# NOTE: https://wiki.gentoo.org/wiki/Gentoo_Cheat_Sheet
# NOTE: to find USE flags, use `equery uses <application>`
# NOTE: to install equery, `emerge gentoolkit`
# NOTE: For writing an ebuild
#   https://devmanual.gentoo.org/eclass-reference/#contents

# XXX: NOTE:
#  when using emerge, after downloading package info using emerge --sync,
#  and having updated the system binaries to their latest versions,
#  root modifications will be saved in a global tracker stored in the chroot
#  using emerge with --oneshot SHOULD prevent us from needing to run
#  one of `dispatch-conf`, `cfg-update`, `etc-update`. All of which are tools
#  designed to prevent us from merging incompatible configurations together
#  in the same root filesystem. This doesn't work 100% as intended, as using
#  an alternate --root doesn't modify the global tracker location. But this is
#  information we need to know to get compilation to worka
#
# WARNING:
#  When interpreting the output of emerge as an ebuild preview, packages
#  destined for INSIDE the initramfs will have the /mnt/initramfs path appended
#  in their list options. All other packages are build dependencies and will
#  remain on the gentoo chroot. Fixing broken build dependencies looks like
#  very erronious behavior as the USE flags don't propagate to the destination.
#  They adhear to the global USE flags set by the build environment chroot.


# NOTE: (split-usr) is forced on by Gentoo's build system which means after
#   we install all our packages, we'll need to install and run the merge-usr
#   script inside the build directory to fix the issue.
cat /mnt/passvm/assets/gentoo-useflags | grep -Eve '^#' | read -rd '' USE;
export USE="$USE";

# TODO: Resolve the below problems:
# QA Notice: Symbolic link /var/run points to /run which does not exist.
# QA Notice: Symbolic link /var/lock points to /run/lock which does not exist.
# QA Notice: Symbolic link /etc/mtab points to /proc/self/mounts which does not exist.
#
# Warning: tmpfiles.d not processed on ROOT != /. If you do not use
#   a service manager supporting tmpfiles.d, you need to run
#   the following command after booting (or chroot-ing with all
#   appropriate filesystems mounted) into the ROOT:
#
#     tmpfiles --create
#
#   Failure to do so may result in missing runtime directories
#   and failures to run programs or start services.
#   Note that kernel backend is very slow for this type of operation
#   and is provided mainly for embedded systems wanting to avoid
#   userspace crypto libraries.
#
# NOTE: CONFIG_DM_CRYPT must be set for speedy cryptsetup functionality
#   Probably also a good idea to compile with kernel crypto turned off
#   didn't think about this earlier, but we also need openssl for GnuPG
#   So using kernel crypto is actually out of the picture
#
# NOTE: We can use Gentoo to build Bash for the initramfs because the following
#   confuration options are the only ones required, exclusive to Bash and the're
#   all enabled by default flags:
#     --enable-brace-expansion
#     --enable-cond-command
#     --enable-cond-regexp
#     --enable-extended-glob
#     --enable-job-control
#   It's possible we could shrink the size of Bash by disabling any features
#   we don't explicitly need. That's a problem for future me.

PARTIAL='false';
P_PACKAGES='false';
P_RAMFS='false';
P_KERNEL='false';
while test "$#" -gt 0; do
	case "$1" in
		'-P'|'--emerge') PARTIAL='true';;
		'-p'|'--packages') P_PACKAGES='true'; PARTIAL='true';;
		'-r'|'--ramfs') P_RAMFS='true'; PARTIAL='true';;
		'-k'|'--kernel') P_KERNEL='true'; PARTIAL='true';;
		'-h'|'--help') help; exit 0;;
		*) perror "unrecognized argument flag! $1"; exit 1;;
	esac;
	shift;
done;

if ! $PARTIAL || $P_PACKAGES; then
	# Host system build tools.
	emerge \
		binutils;

	# Build deps in host unless building LibC requires alternate ROOT for
	# effective compilation; Though while I'm thinking about it making it
	# use an alternate root could make this easier to convert / port to an ebuild.
	emerge \
			cryptsetup \
			app-crypt/gnupg \
			app-editors/nano \
			bash;

	{
	# Stage Busybox for build
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
		cd busybox-1.36.1;
		cp -u "$PASSVM_DIR"/assets/busybox-1.36.1-config .config;
		make;
	}
fi;

# TODO: look into https://github.com/cifsd-team/ksmbd-tools to set up
#   a Kernel based SMB3 + CIFS server FUCKING SAMBA!
#   Depends on kernel CONFIG_SMB_SERVER=y

{
	cd linux-6.4.12;
	cp -u "$PASSVM_DIR"/assets/linux-6.4.12-config .config;
	
	if ! $PARTIAL || $P_RAMFS; then
		"$PASSVM_DIR/tools/mustache.sh" \
			"$PASSVM_DIR/templates/cpio.base.mustache" > \
				passvm.cpio.cfg;
	
		"$PASSVM_DIR/tools/mustache.sh" \
			"$PASSVM_DIR/templates/cpio.config.mustache" >> \
				passvm.cpio.cfg;
	
		"$PASSVM_DIR/tools/mustache.sh" \
			"$PASSVM_DIR/templates/cpio.elfdeps.mustache" \
			| tee -a passvm.cpio.cfg \
			| "$PASSVM_DIR/tools/elf2cpio.sh" -S -x -l "/lib/" - \
			| tee -a passvm.cpio.cfg > "$PASSVM_DIR/templates/cpio.sodeps.mustache";

		# Create initramfs as regular user
		gcc -o usr/gen_init_cpio usr/gen_init_cpio.c;
		./usr/gen_initramfs.sh -o passvm.cpio ./passvm.cpio.cfg;
	fi;

	if ! $PARTIAL || $P_KERNEL; then
		# Build the kernel with builtin initramfs
		make;
	fi;
}
