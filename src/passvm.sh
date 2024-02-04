#!/bin/sh -e
# @file - passvm.sh
# @brief - virtualized password manager passthrough. 

XDG_DATA_HOME="${XDG_DATA_HOME:=$HOME/.local/share}";
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:=$HOME/.config}";
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:=/tmp}";




mkdir -p "${XDG_CONFIG_HOME}/passvm";
mkdir -p "${XDG_DATA_HOME}/passvm";
cd "${XDG_DATA_HOME}/passvm";


if false && ! test -f fs.qcow2; then
	# TODO: Figure out if -loadvm is useful for speeding up load time.
	qemu-img create -f qcow2 -o preallocation=off fs.qcow2 50M;
fi;

# Execute virtual environment.
# Below are some params that almost make raw stdio possible, but
# adding -serial mon:stdio to curses graphic mode allows the use
# of the qemu CLI from curses. However the CTRL capture is jank.
# -nographic
# -serial mon:stdio
# -append "console=ttyS0"
qemu-system-x86_64 \
	-cpu qemu \
	-accel tcg \
	-display curses \
	-kernel vmlinuz64;
#	-loadvm ready;
