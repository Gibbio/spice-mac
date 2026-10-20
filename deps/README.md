# Native dependencies

[`scripts/build-deps.sh`](../scripts/build-deps.sh) builds SpiceMac's native SPICE
stack (spice-gtk, glib, GStreamer, OpenSSL, …) from source into `Sysroot/`. What it
builds is described here:

- **`sources.lock`** — every package, in build order, one line each. Releases are
  pinned by URL and SHA-256; the SPICE projects (spice-gtk, spice-protocol,
  usbredir) by git commit, since they tag releases rarely. The build fails closed on
  any mismatch.
- **`patches/<package>/`** — our changes on top of upstream, applied in order
  (`git format-patch` files; author and reason in each).

Build options per package are in `build_<package>()` in `build-deps.sh`. A package
is rebuilt whenever its `sources.lock` line, its patches or those options change.

## Updating a package

Edit its line in `sources.lock`, then run `./scripts/build-deps.sh`:

- **A release:** new version and URL. The build stops with the SHA-256 it got —
  check it against the one upstream publishes (or the release signature) and put it
  in the line.
- **A git package:** the new commit id (`git ls-remote <url> <branch>`).

`gstreamer`, `gst-plugins-base` and `gst-plugins-good` always move together. A
spice-gtk update may need a newer `spice-protocol` (meson says so). After a large
jump (glib, GStreamer) use `./scripts/build-deps.sh --clean` so everything above it
is rebuilt. Then `make build` and re-test against a VM: display, input, clipboard,
audio, USB menu, a video stream.

## When a patch no longer applies

The build stops at `patch failed: …`. Re-apply the series with git on the new
source, fix the conflicts, and export it back:

```sh
git clone https://gitlab.freedesktop.org/spice/spice-gtk.git && cd spice-gtk
git checkout <new commit>              # for a release: unpack the tarball, git init, commit
git am -3 ../spice-mac/deps/patches/spice-gtk/*.patch     # fix, git add, git am --continue
git format-patch --no-signature --zero-commit <new commit>..HEAD \
    -o ../spice-mac/deps/patches/spice-gtk                # after removing the old files
```

Check the result for leftover `<<<<<<<` lines before exporting: a resolution
committed by mistake still applies cleanly.

## Rules

- **spice-gtk runs on CocoaSpice's own GMainContext.** Patches 0001–0002 route its
  idle/timeout sources there through `g_spice_*()`; a plain `g_idle_add` /
  `g_timeout_add` would land on a context nothing iterates. Upstream can add one in
  any commit, so the build refuses to continue if it finds one — convert it in 0002.
- **No GPL** in anything built or bundled: check a new package's license and add it
  to `../THIRD-PARTY-LICENSES.txt` and `../licenses/`.
- **Hermetic:** Homebrew provides only tools (meson, ninja, cmake, pkg-config,
  bison); the final check rejects any library that references `/opt/homebrew`, a
  path outside `@rpath` and the OS, or a macOS newer than 12.
