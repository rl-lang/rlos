# Vendored bubblewrap documentation

These are the upstream documents for bubblewrap, copied verbatim rather than
paraphrased, so that the reference on the image is the real thing and not
someone's summary of it. Paraphrasing a man page is how you end up shipping
documentation for flags the shipped binary does not have.

## Files and where they came from

| File | Upstream source | Version |
|---|---|---|
| `bwrap.1` | `/usr/share/man/man1/bwrap.1.bz2` on the build host (Debian's roff man page) | 0.12.0 |
| `bubblewrap-README.v0.12.0.md` | `https://raw.githubusercontent.com/containers/bubblewrap/v0.12.0/README.md` | 0.12.0 |

Both are pinned to **0.12.0** because that is the version
`rlos-atom/build_atom_bwrap.sh` stages, verified with `bwrap --version`:

```
bubblewrap 0.12.0
```

## Why the version matters

The README is fetched from a *tag*, not from `main`. Documentation for a moving
branch describes whatever the author is working on, which is not necessarily
what is on this machine. If a future build stages a different bubblewrap, these
two files have to be re-vendored from that version's tag, or the reference on
the image will quietly disagree with the binary next to it.

## Re-vendoring

To refresh, note the new version and replace both files from its tag:

```sh
VER=0.12.0
base=https://raw.githubusercontent.com/containers/bubblewrap/v$VER
curl -fsSL -o "bubblewrap-README.v$VER.md" "$base/README.md"
bunzip2 -c /usr/share/man/man1/bwrap.1.bz2 > bwrap.1
```

Then update the version in `assemble-rootfs.sh`'s staging block and the pinned
filename in the docs table above, so a stale vendored copy is visible in a diff
rather than discovered on the machine.

## Checksums at vendoring time

```
94844972d1ea35c6e12d6ec1a558a774c941306e3ff5b7117a7c85137a35eea0  bubblewrap-README.v0.12.0.md
```

`bwrap.1` came from the host's man database rather than the upstream tarball, so
it has no upstream checksum to compare against; its version is confirmed by the
`bwrap --version` check above rather than by the file itself.