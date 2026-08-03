#!/bin/sh
# atom-web.sh - an atom container serving files over HTTP.
#
# Demonstrates the thing that makes a shared netns useful: a server inside the
# container binds a port that is also a port on the host, so there is nothing to
# forward. bwrap cannot forward ports and this kernel has no CONFIG_VETH, so a
# private network namespace would be unreachable from outside - sharing the host
# network is what makes the port reachable at all.
#
#   HOST=0.0.0.0  curl http://localhost:8080/   from this machine
#   curl http://<your-ip>:8080/                from anywhere on the network
#
# Note there is no authentication. That is the deal with a busybox httpd on a
# LAN: put it behind a port you only bind to loopback, or do not run it.
set -eu

ROOT="${ATOM_DEST:-$HOME/atom}"
PORT="${ATOM_PORT:-8080}"
DATA="${ATOM_DATA:-$HOME/atom-data}"
DOCROOT="${ATOM_DOCROOT:-$DATA/www}"

[ -x "$ROOT/bin/busybox" ] || {
    echo "atom-web: $ROOT is not unpacked - run ~/scripts/atom-make.sh first" >&2
    exit 1
}

# busybox httpd serves this directory. Creating it inside DATA rather than in the
# image is what makes it survive the container: everything under the image is
# read-only and discarded, this one path is a bind.
mkdir -p "$DOCROOT"
if [ -z "$(ls -A "$DOCROOT" 2>/dev/null)" ]; then
    cat > "$DOCROOT/index.html" << 'HTMLEOF'
<!doctype html>
<meta charset="utf-8">
<title>atom</title>
<h1>atom</h1>
<p>Served by busybox httpd inside a bubblewrap container.</p>
<p>Edit <code>~/atom-data/www/index.html</code> and reload.</p>
HTMLEOF
    echo "atom-web: wrote a placeholder index.html into $DOCROOT"
fi

  echo "atom-web: serving $DOCROOT on port $PORT"
  echo "         curl http://localhost:$PORT/"
  echo
  echo "         from another host: curl http://$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1):$PORT/"
  echo "         scp into it via atom-ssh.sh (it is a separate container - this one has no sshd)"
  echo "         Ctrl-C stops it. Another container needs a different ATOM_PORT."
  echo

# The flags are annotated above rather than inline: a comment inside a
# backslash-continued command truncates it silently, bwrap then prints its help,
# and the failure looks like a bwrap problem rather than a shell one.
#
#   --ro-bind $ROOT /       image, read-only.
#   --tmpfs /tmp /run       scratch and a writable /run for pidfiles.
#   --unshare-*             private user/pid/uts/ipc. NOT net - see below.
#   --bind $DATA /var/lib/atom  the writable path httpd serves out of.
#   --chdir                 start in the document root.
#
# No --unshare-net: the container shares the host network, so the port httpd binds
# is a host port and needs no forwarding. bwrap cannot forward ports and this
# kernel has no CONFIG_VETH, so sharing the network is the only way the port is
# reachable at all.
#
# The program: /bin/httpd -f stays in the foreground so Ctrl-C works and the
# container's lifetime is this process's; -p is the port; -h is the document root,
# which is the writable bind rather than the image.
exec bwrap \
    --ro-bind "$ROOT" / \
    --proc /proc \
    --dev /dev \
    --tmpfs /tmp \
    --tmpfs /run \
    --unshare-user \
    --unshare-pid \
    --unshare-uts \
    --hostname atom \
    --unshare-ipc \
    --die-with-parent \
    --bind "$DATA" /var/lib/atom \
    --chdir /var/lib/atom \
    --setenv HOME /root \
    --setenv PATH /bin:/usr/bin:/sbin:/usr/sbin:/bin \
    -- \
    /bin/httpd -f -p "$PORT" -h /var/lib/atom/www
