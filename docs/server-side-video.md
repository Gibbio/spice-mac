# Better video with changes on the Proxmox node

SpiceMac on its own gets the most out of a stock Proxmox node: MJPEG streams at
the frame rate the server sends, ~150 ms from a click to the screen and no
dropped frames (README ▸ *Video streaming*). Going further — 30 fps H.264 at a
few Mbit/s — takes changes on the node. They are described here as levels, each
building on the previous one.

Keep in mind before trying any of them:

- **They change the node, not the VM.** A library or plugin installed on the node
  is used by every VM started afterwards, including VMs that have nothing to do
  with SpiceMac.
- **The numbers come from one setup.** Node: Intel Core i5-14400 (UHD Graphics
  730, `i915`), Proxmox VE 9.2, pve-qemu-kvm 11.0.3. Guest: Windows 11 on `qxl`
  with `videostreaming=all`. Client: SpiceMac on an M4 Mac, same LAN. Content: a
  browser page panning a 1449×805 picture at 30 fps, either *smooth* (video-like)
  or with per-frame *noise* (the worst case for any codec). CPU figures are % of
  one core.
- **Level 3 is hardware-specific.** Its encoder settings were checked on this one
  Intel GPU only.

## Summary

| Level | On the node | Codec | fps | Bandwidth (smooth) | Node CPU | Client needs |
|---|---|---|---|---|---|---|
| 0 | nothing (Proxmox VE 9, spice-server 0.15.2) | MJPEG | 23 | 15 Mbit/s (37–50 with noise) | 5–9% | — |
| 1 | + `gstreamer1.0-plugins-ugly` (x264) | H.264, software | 30.7 | 6.6 Mbit/s (59 with noise) | 37% (48% with noise) | 0010 |
| 2 | + spice-server master, own package | H.264, software | 30.8 | 5.6 Mbit/s | 38% | 0010, 0011 |
| 3 | + VA-API (Quick Sync), two local patches | H.264, GPU | 29.7 | 3.2 Mbit/s | 7% | 0010, 0011 |

The client patches are in `deps/patches/spice-gtk/`, and current SpiceMac builds
have them. H.264 is still opt-in: start SpiceMac with
`SPICE_PREFERRED_VIDEO_CODECS=h264,mjpeg`, e.g.
`open build/SpiceMac.app --env SPICE_PREFERRED_VIDEO_CODECS=h264,mjpeg conn.vv`.
Without it the server keeps sending MJPEG at every level.

## Level 0: stock Proxmox

Nothing to change beyond the VM settings in the README (`qxl`, `videostreaming`).
spice-server 0.15.2 has no H.264 encoder until GStreamer's x264 plugin is
installed, so streams are MJPEG. The server does not send MJPEG faster than
~23 fps here.

## Level 1: H.264 with x264

```sh
apt-get install --no-install-recommends \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly
qm reboot <vmid>      # a new QEMU process picks the plugins up
```

All 30 frames get through, at less than half of MJPEG's bandwidth on smooth
content. The cost is on the node: spice-server converts every frame from RGB and
encodes it in software (x264 `ultrafast`, settings fixed in the server's source),
about a third of a core per stream at this size and more with busy content. Every
further stream or VM adds to that.

Patch 0010 is required. Before it, SpiceMac sent its codec preference as soon as
the display channel opened, and every spice-server from 0.15.2 up to master
crashed (killing QEMU, so the VM) if a video was already playing at that moment.
It is a server bug, reported upstream as
[spice/spice#99](https://gitlab.freedesktop.org/spice/spice/-/issues/99) with a
proposed fix; SpiceMac now sends the preference when the server is ready for it,
so it does not need that fix.

## Level 2: spice-server 0.16 or later

Proxmox VE 9 (Debian trixie) ships spice-server 0.15.2. Level 3 needs 0.16 or
later, which looks for Intel hardware encoders on its own. We built git master
**ad4b603d** (0.16.0 + 55 commits) as a Debian package; the 0.16.0 release itself
was not tested.

Building it, in a Debian trixie amd64 container (on Apple silicon, Docker or
Colima with amd64 emulation works, slowly; rerun a step if the linker crashes
under emulation):

1. Build and install Debian's spice-protocol 0.14.5 (from forky): spice-server
   0.16 needs it at build time only.
2. Clone spice-server, check out the commit, and add the `debian/` directory of
   Debian's spice 0.16.0-3 source package. Give it a changelog entry with a local
   version above 0.15.2, e.g. `0.16.0+git20261015.ad4b603-1~local1`.
3. Add `spice_server_get_port` (new in master) to
   `debian/libspice-server1.symbols`, then `dpkg-buildpackage -b -us -uc`.
4. Check that every `spice_*` symbol the node's QEMU imports
   (`nm -D --undefined-only /usr/bin/qemu-system-x86_64`) is exported by the new
   `libspice-server.so.1`.
5. On the node, install only `libspice-server1_<version>_amd64.deb` and restart
   the VM.

Since 0.16 the server sends the client its real time instead of a clock running
400 ms behind, and leaves the playout delay to the client
([MR !226](https://gitlab.freedesktop.org/spice/spice/-/merge_requests/226)).
Patch 0011 adapts SpiceMac to that. Without it, the frames looked late to the
server, whose rate control cut MJPEG to 8 fps and ~1 Mbit/s. With it, MJPEG is the
same as at level 0, and H.264 matches level 1. Other clients (remote-viewer,
virt-viewer) may hit the same MJPEG cut; that was not tested.

## Level 3: H.264 on the GPU (Quick Sync)

```sh
apt-get install --no-install-recommends gstreamer1.0-vaapi intel-media-va-driver vainfo
vainfo      # H.264 must be listed with an encode entrypoint (EncSlice or EncSliceLP)
qm reboot <vmid>
```

When the node has an Intel GPU, spice-server 0.16 looks for an `msdk`, `va` or
`vaapi` H.264 encoder and uses it in place of x264, converting colours on the GPU
too. `gstreamer1.0-vaapi` provides `vaapih264enc` with 18 packages, all
libraries. The alternative, `gstreamer1.0-plugins-bad`, pulls in 116 packages,
GTK and SDL among them, which a hypervisor does not need. On a GPU like this one,
whose H.264 encoder is low-power only (`VAEntrypointEncSliceLP`), its `va` plugin
should also only offer `vah264lpenc`, which the server does not look for (not
tried). The GPU must not be passed through to a VM.

With the server's own settings (constant QP 26), streams were 30 fps at 1.7 Mbit/s
and 11% of a core, but visibly softer than x264, which runs at QP 15 on most
desktop content. We changed two things in the server, applied as patches in
`debian/patches/` of the package built at level 2:

- **Constant quality instead of constant QP.** QVBR at quality 16 keeps the
  picture close to x264's and lets the bitrate follow the content, capped by the
  bitrate the server's rate control picks. Which rate controls exist depends on
  the GPU and driver (this one offers CBR, VBR, CQP, QVBR, but not ICQ), so this
  is not a general default.

  ```diff
  --- a/server/gstreamer-encoder.c
  +++ b/server/gstreamer-encoder.c
  @@ static gchar *get_hw_gstenc_opts(const gchar *encoder, const gchar *codec_name)
           } else {
  -            gstenc_opts = g_strdup("rate-control=cqp max-bframes=0 min-qp=15 max-qp=35");
  +            gstenc_opts = g_strdup("rate-control=qvbr quality-factor=16 max-bframes=0 min-qp=15 max-qp=35");
           }
  ```

- **Bitrate unit.** The server divides the bitrate by 1024 only when the
  encoder's property description says `kbit`. `vaapih264enc` says `kbps`, so it
  got a cap 1024 times too high.

  ```diff
  --- a/server/gstreamer-encoder.c
  +++ b/server/gstreamer-encoder.c
  @@ static void set_gstenc_bitrate(SpiceGstEncoder *encoder)
       uint64_t gst_bit_rate = encoder->video_bit_rate;
  -    if (strstr(g_param_spec_get_blurb(param), "kbit")) {
  +    const gchar *blurb = g_param_spec_get_blurb(param);
  +    if (strstr(blurb, "kbit") || strstr(blurb, "kbps")) {
           gst_bit_rate = gst_bit_rate / 1024;
       }
  ```

Results on smooth content:

| Encoder settings | fps | Bandwidth | Node CPU | Picture |
|---|---|---|---|---|
| server default (CQP, QP 26) | 30.8 | 1.7 Mbit/s | 10.8% | softer than x264 |
| CQP, QP 16 | 29.2 | 7.9 Mbit/s | 10.9% | good |
| **QVBR, quality 16** | **29.7** | **3.2 Mbit/s** | **6.8%** | **very good** |

From the command line on the node, at 1440×800, a frame took ~6.7 ms of CPU with
x264 and ~0.4 ms with Quick Sync.

One drawback: starting a VA pipeline takes time, so the picture pauses for about
0.3 s each time the server creates a stream (when a video starts or moves).

## Going back

```sh
apt-get install --allow-downgrades libspice-server1=0.15.2-1+b1     # level 2
apt-get purge gstreamer1.0-vaapi intel-media-va-driver vainfo        # level 3
apt-get purge gstreamer1.0-plugins-ugly                              # level 1
qm reboot <vmid>
```

Purge `gstreamer1.0-plugins-base` and `-good` too if they were installed only for
level 1. Each VM keeps the old libraries until its QEMU process restarts.
