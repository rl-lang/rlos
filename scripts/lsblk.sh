#!/bin/sh
#
# lsblk - list block devices as a tree.
#
# WHY THIS EXISTS
# ---------------
# busybox has no lsblk. Not "not enabled" - the applet does not exist in
# busybox 1.37 at all: there is no lsblk.c anywhere in the tree, so there is no
# config symbol to turn on. build_busybox.sh enables every applet busybox does
# have; this is a gap in busybox itself, not a gap in our config.
#
# Nor can busybox's blkid stand in for it. busybox ships a trivial blkid -
# util-linux/blkid.c is a 1 KiB shim and FEATURE_BLKID_TYPE is not enabled -
# which prints UUIDs and nothing else: no TYPE, no LABEL, no -L, no -s, no -o.
# That is enough to answer "what is on this one filesystem" and not enough to
# build a listing from.
#
# So each column is read from wherever the kernel and udev actually keep it:
#
#   NAME         /sys/class/block/<name>
#   MAJ:MIN      <name>/dev
#   SIZE         <name>/size, in 512-byte sectors
#   RO           <name>/ro
#   RM           <name>/removable
#   TYPE         <name>/partition existing means part; else slaves/ or a dm
#                uuid means crypt, lvm or raid; else it is a whole disk
#   FSTYPE       /run/udev/data/c<major>:<minor>, E:ID_FS_TYPE
#   LABEL        the same file, E:ID_FS_LABEL
#   MOUNTPOINTS  /proc/self/mountinfo
#
# mountinfo rather than /proc/mounts, because /proc/mounts names the device by
# *path* and that path would then have to be resolved back to a major:minor to
# be matched against sysfs. mountinfo carries major:minor in field 3 directly,
# so nothing has to be resolved. Its field 5 is the mountpoint and the field
# after the lone "-" separator is the filesystem type.
#
# FSTYPE and LABEL come from udev rather than from mountinfo because mountinfo
# only describes filesystems that are mounted: an unmounted partition that
# still has a filesystem on it would show neither, and "what is on sdb1" is
# precisely the question someone runs lsblk to ask.
#
# POSIX sh throughout, because the shell here is busybox ash. That rules out
# arrays, printf's %'d, and numfmt/column/bc - so the sizes are formatted in
# awk, which does the column widths as well.

SYS=/sys/class/block
MOUNTINFO=/proc/self/mountinfo
UDEV_DATA=/run/udev/data

want_bytes=0
want_paths=0
disks_only=0
no_header=0

usage()
{
	cat << 'EOF'
Usage: lsblk [OPTIONS]

List block devices, with partitions nested under their disk.

  -b, --bytes      print SIZE in bytes rather than in human-readable units
  -d, --nodeps     only print whole disks, no partitions
  -n, --noheadings do not print a header row
  -p, --paths      print full device paths, not just device names
  -h, --help       print this message
EOF
}

udev_prop()
{
	# $1 is major:minor, $2 the key. Prints the value, or nothing if absent.
	# The file is KEY=value lines prefixed by a one-letter tag, E: for a
	# property and G: for a database entry, so the tag has to be matched too.
	# This is the same trick init.c's udev_prop() uses, and for the same
	# reason: it is the only way to read a tag without linking libudev.
	[ -r "$UDEV_DATA/c$1" ] || return 0
	grep "^E:$2=" "$UDEV_DATA/c$1" 2>/dev/null | sed "s/^E:$2=//" | head -1
}

while [ $# -gt 0 ]; do
	case $1 in
	-b | --bytes)      want_bytes=1 ;;
	-d | --nodeps)     disks_only=1 ;;
	-n | --noheadings) no_header=1 ;;
	-p | --paths)      want_paths=1 ;;
	-h | --help)       usage; exit 0 ;;
	--)                shift; break ;;
	*)                 echo "lsblk: unrecognized option '$1'" >&2
	                   usage >&2
	                   exit 1 ;;
	esac
	shift
done

if [ $# -gt 0 ]; then
	echo "lsblk: unexpected operand '$1'" >&2
	exit 1
fi

[ -d "$SYS" ] || { echo "lsblk: $SYS not found - not Linux?" >&2; exit 1; }

# Records go through a file in $TMPDIR rather than a shell variable: it is
# newline-separated text that awk is about to read anyway, so this avoids both
# running the whole thing twice and mangling anything through word splitting.
REC="${TMPDIR:-/tmp}/.lsblk.$$"
trap 'rm -f "$REC"' EXIT INT TERM

for d in "$SYS"/*; do
	[ -d "$d" ] || continue
	[ -r "$d/dev" ] || continue

	name=${d##*/}
	majmin=$(cat "$d/dev" 2>/dev/null)
	[ -n "$majmin" ] || continue

	sectors=$(cat "$d/size" 2>/dev/null) || sectors=0
	[ -n "$sectors" ] || sectors=0
	ro=$(cat "$d/ro" 2>/dev/null) || ro=0
	rmflag=$(cat "$d/removable" 2>/dev/null) || rmflag=0
	[ -n "$ro" ] || ro=0
	[ -n "$rmflag" ] || rmflag=0

	# A partition is the only kind of device with a "partition" file holding
	# its index within the parent disk.
	if [ -f "$d/partition" ]; then
		vtype=part
		# A partition's resolved sysfs path ends in block/<disk>/<part>, so
		# the parent disk is the directory above it. For a device-mapper node
		# the path ends in virtual/block/<name> instead, which would come out
		# as the useless name "block".
		parent=$(basename "$(dirname "$(readlink -f "$d" 2>/dev/null)" 2>/dev/null)" 2>/dev/null)
		case $parent in
		block | "") parent= ;;
		esac
	else
		parent=
		vtype=disk
		# A device with slaves is stacked on something else. dm records what
		# it is in its uuid; md records the RAID level and has no dm directory.
		if [ -d "$d/slaves" ] && [ -n "$(ls "$d/slaves" 2>/dev/null)" ]; then
			parent=$(ls "$d/slaves" 2>/dev/null | tr '\n' ',' | sed 's/,*$//')
			vtype=other
			case $(cat "$d/dm/uuid" 2>/dev/null) in
			CRYPT-LUKS*) vtype=crypt ;;
			LVM-*)       vtype=lvm ;;
			esac
			level=$(cat "$d/md/level" 2>/dev/null)
			if [ -n "$level" ]; then
				vtype=raid
				parent=
			fi
		fi
	fi

	if [ "$disks_only" = 1 ] && [ "$vtype" != disk ]; then
		continue
	fi

	fstype=$(udev_prop "$majmin" ID_FS_TYPE)
	label=$(udev_prop "$majmin" ID_FS_LABEL)

	# Tab and newline are the field separators, so any occurrence of them in
	# a label has to go or it would shift every column after it. Nothing else
	# reaching here can contain whitespace: the other fields are sysfs
	# integers, udev tokens, or a comma-separated slave list.
	label=$(printf '%s' "$label" | tr '\t\n' '  ')

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$name" "$majmin" "$sectors" "$ro" "$rmflag" \
		"$vtype" "$parent" "$fstype" "$label" >> "$REC"
done

if [ ! -s "$REC" ]; then
	echo "lsblk: no block devices found"
	exit 0
fi

# awk here is busybox awk: byte-oriented, and length() counts bytes. That is
# why the box-drawing connectors are printed outside the padded name field
# rather than inside it - NAME itself is always ASCII, so the padding maths
# stays correct, while the connectors can still be real UTF-8.
awk -v bytes="$want_bytes" -v paths="$want_paths" \
    -v hdr="$no_header" -v rec="$REC" -v mountinfo="$MOUNTINFO" '
function human(s,   n, u, i) {
	if (bytes)
		return sprintf("%d", s)
	n = s * 512
	if (n < 1024)
		return sprintf("%d", n) "B"
	# util-linux lsblk labels these K, M, G, T rather than KiB, MiB, GiB,
	# and keeps one decimal from the megabyte mark upwards.
	split("K M G T P E", u, " ")
	for (i = 1; i <= 6; i++) {
		n /= 1024
		if (n < 1024 || i == 6)
			return (i == 1 ? sprintf("%.0f%s", n, u[i]) : sprintf("%.1f%s", n, u[i]))
	}
}
function ljust(s, w,   d) {
	s = s ""
	d = w - length(s)
	while (d-- > 0)
		s = s " "
	return s
}
function rjust(s, w,   d) {
	s = s ""
	d = w - length(s)
	while (d-- > 0)
		s = " " s
	return s
}
BEGIN {
	while ((getline line < rec) > 0) {
		n++
		split(line, f, "\t")
		name[n] = f[1]
		majmin[f[1]] = f[2]
		sectors[f[1]] = f[3] + 0
		ro[f[1]] = f[4] + 0
		rmf[f[1]] = f[5] + 0
		vtype[f[1]] = f[6]
		parent[f[1]] = f[7]
		fstype[f[1]] = f[8]
		vlabel[f[1]] = f[9]
	}
	close(rec)

	# mountinfo field 3 is major:minor and field 5 the mountpoint. Several
	# lines can share one device - btrfs mounts several subvolumes - so the
	# mountpoints accumulate into a comma-separated list.
	while ((getline mi < mountinfo) > 0) {
		c = split(mi, g, " ")
		for (i = 7; i <= c; i++)
			if (g[i] == "-") {
				mi_fs = g[i + 1]
				break
			}
		mp[g[3]] = mp[g[3]] (mp[g[3]] == "" ? "" : ", ") g[5]
		# Only used as a fallback for devices udev never classified.
		if (mi_fs != "" && mi_fs != "rootfs" && !(g[3] in fs_of))
			fs_of[g[3]] = mi_fs
	}

	# Whole disks in the order they were found, then everything else filed
	# under the disk it ultimately belongs to. A partition names its disk
	# directly; a stacked device - dm, md - names a slave instead, so with a
	# single slave the owner is one step further up. Anything that resolves to
	# no disk at all - several slaves, or a slave that is not on this machine -
	# is listed at the end rather than dropped, because a device you cannot
	# see is worse than one printed in the wrong place.
	for (i = 1; i <= n; i++) {
		dev = name[i]
		if (vtype[dev] == "disk") {
			disk[++ndisk] = dev
			continue
		}
		p = parent[dev]
		if (vtype[dev] != "part" && p != "" && index(p, ",") == 0 && p in vtype)
			p = vtype[p] == "disk" ? p : parent[p]
		else if (index(p, ",") > 0)
			p = ""
		if (p != "" && p in vtype && vtype[p] == "disk")
			child[p] = child[p] " " dev
		else
			extra[++nextra] = dev
	}

	# Resolve the filesystem type now that both sources are known, so the
	# column width is measured against what actually gets printed.
	for (i = 1; i <= n; i++) {
		dev = name[i]
		if (fstype[dev] == "" && majmin[dev] in fs_of)
			fstype[dev] = fs_of[majmin[dev]]
		vsize[dev] = human(sectors[dev])
		vname[dev] = paths ? "/dev/" dev : dev

		if (length(vname[dev]) > w_name) w_name = length(vname[dev])
		if (length(majmin[dev]) > w_maj) w_maj = length(majmin[dev])
		if (length(vsize[dev]) > w_size) w_size = length(vsize[dev])
		if (length(vtype[dev]) > w_type) w_type = length(vtype[dev])
		if (length(fstype[dev]) > w_fs) w_fs = length(fstype[dev])
		if (length(vlabel[dev]) > w_label) w_label = length(vlabel[dev])
	}
	if (w_maj < 6) w_maj = 6
	if (w_type < 4) w_type = 4

	}
END {
	if (!hdr)
		printf "%s %s %s %s %s %s %s %s %s\n",
			ljust("NAME", w_name), rjust("MAJ:MIN", w_maj), rjust("RM", 2),
			rjust("SIZE", w_size), rjust("RO", 2), ljust("TYPE", w_type),
			ljust("FSTYPE", w_fs), ljust("LABEL", w_label), "MOUNTPOINTS"

	for (i = 1; i <= ndisk; i++) {
		d = disk[i]
		emit(d, "")
		k = split(child[d], kids, " ")
		for (j = 1; j <= k; j++)
			if (kids[j] != "") emit(kids[j], (j < k ? "├─ " : "└─ "))
	}
	for (i = 1; i <= nextra; i++)
		emit(extra[i], "")
}
function emit(dev, conn,   pre) {
	if (!(dev in vtype))
		return
	pre = conn
	# A device-mapper or md entry lists its slaves as "sda2,sda3"; lsblk shows
	# that alongside the row rather than as a tree edge, because there is no
	# single parent to hang it from.
	if (index(parent[dev], ",") > 0)
		pre = pre " (" parent[dev] ")"
	printf "%s %s %s %s %s %s %s %s %s\n",
		ljust(pre vname[dev], w_name), rjust(majmin[dev], w_maj),
		rjust(rmf[dev], 2), rjust(vsize[dev], w_size), rjust(ro[dev], 2),
		ljust(vtype[dev], w_type), ljust(fstype[dev], w_fs),
		ljust(vlabel[dev], w_label), mp[majmin[dev]]
}
'
rc=$?
exit $rc