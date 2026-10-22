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
| 3 | + VA-API (Quick Sync), local patches | H.264, GPU | 29.7 | 3.2 Mbit/s | 7% | 0010, 0011, 0016, 0023, 0024 |

The client patches are in `deps/patches/spice-gtk/`, and current SpiceMac builds
have them. H.264 is still opt-in: turn on **Connection ▸ Prefer H.264 Video**
(or start SpiceMac with `SPICE_PREFERRED_VIDEO_CODECS=h264,mjpeg`). Without it
the server keeps sending MJPEG at every level. **View ▸ Show Statistics** shows
which codec each stream really uses and how many frames get through.

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
apt-get install --no-install-recommends intel-media-va-driver gstreamer1.0-plugins-base \
    ./gstreamer1.0-va-local.deb      # GStreamer's va plugin alone, built below
qm reboot <vmid>
```

When the node has an Intel GPU, spice-server 0.16 looks for an `msdk`, `va` or
`vaapi` H.264 encoder and uses it in place of x264, converting colours on the GPU
too. The GPU must not be passed through to a VM. We use the `va` plugin's
`vah264lpenc`; `gstreamer1.0-vaapi`'s `vaapih264enc`, which we tried first,
fails at every stream size change (below). The `va` plugin comes only inside
`gstreamer1.0-plugins-bad`, with 133 more packages here, so we package its one
file: with it, the server package and the lines above, 31 packages on our node,
all of them Debian's except those two. Optionally, `vainfo` (package `vainfo`)
lists H.264 with an `EncSliceLP` entrypoint on such a GPU.

With the server's own settings (constant QP 26), streams were 30 fps at 1.7 Mbit/s
and 11% of a core, but visibly softer than x264, which runs at QP 15 on most
desktop content. The patches below are applied in `debian/patches/` of the
package built at level 2. The first two came with `vaapih264enc`:

- **Constant quality instead of constant QP.** QVBR at quality 16 keeps the
  picture close to x264's and lets the bitrate follow the content, capped by the
  bitrate the server's rate control picks. Which rate controls exist depends on
  the GPU and driver (this one offers CBR, VBR, CQP, QVBR, but not ICQ), so this
  is not a general default. This diff sets it for `vaapih264enc` only, and our
  current package no longer carries it: for `vah264lpenc` the same setting is
  part of the `vah264lpenc` patch below.

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
  got a cap 1024 times too high; the `va` plugin's encoders say `kbps` too, and
  this patch stays in our package.

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

Results on smooth content, with `vaapih264enc`:

| Encoder settings | fps | Bandwidth | Node CPU | Picture |
|---|---|---|---|---|
| server default (CQP, QP 26) | 30.8 | 1.7 Mbit/s | 10.8% | softer than x264 |
| CQP, QP 16 | 29.2 | 7.9 Mbit/s | 10.9% | good |
| **QVBR, quality 16** | **29.7** | **3.2 Mbit/s** | **6.8%** | **very good** |

From the command line on the node, at 1440×800, a frame took ~6.7 ms of CPU with
x264 and ~0.4 ms with Quick Sync.

One drawback: starting a VA pipeline takes time, so the picture pauses for about
0.3 s each time the server creates a stream (when a video starts or moves).

### The `va` plugin instead of `vaapi`

On some pages `vaapih264enc` made H.264 unusable: the stream fell to a few fps
and the node's journal had `GStreamer error from element src: Internal data
stream error` about once a second. spice-server changes a stream's size
whenever a frame of another size joins it (e.g. the video plus a line of text
updated next to it: 1282×88 and 1474×88 in turn), and `vaapih264enc` fails the
first frame after every size change, whatever its rate control (`failed to
encode frame`); the server then rebuilds the pipeline. `vah264lpenc`, from
GStreamer's newer `va` plugin, takes the new size when the caps change on the
playing pipeline (40 frames changing size every 2: 40 encoded, 0 errors), but
spice-server takes the pipeline through the NULL state for every change, which
the `va` plugin fails too (22 encoded, 9 errors). Two more patches:

- **Use `vah264lpenc`.** The server only looks for `vah264enc`, which this GPU
  (like other recent Intel ones) lacks; it has the low-power encoder only. With
  it, QVBR at quality 16 as with `vaapi` (`qpi` is the quality there).

  ```diff
  @@ static gchar *find_best_hw_plugin(const gchar *codec_name)
  -        if (!gst_features_lookup(feature_name)) {
  +        if (gst_features_lookup(feature_name)) {
  +            break;
  +        }
  +        g_free(feature_name);
  +        feature_name = NULL;
  +        if (codec_name && strcmp(plugins[i], "va") == 0) {
  +            feature_name = g_strconcat(plugins[i], codec_name, "lpenc", NULL);
  +            if (gst_features_lookup(feature_name)) {
  +                break;
  +            }
               g_free(feature_name);
               feature_name = NULL;
  -            continue;
           }
  -        break;
  @@ static gchar *get_hw_gstenc_opts(const gchar *encoder, const gchar *codec_name)
  -            gstenc_opts = g_strdup("rate-control=16 b-frames=0 target-usage=7 min-qp=15 max-qp=35");
  +            gstenc_opts = g_strdup("rate-control=qvbr qpi=16 b-frames=0 target-usage=7 min-qp=15 max-qp=35");
  ```

- **Change the size while playing.** For the `va` plugin's encoders, a new size
  (and bitrate, which they take live anyway) is set on the running pipeline
  instead of through the NULL state.

  ```diff
  @@ static gboolean create_pipeline(SpiceGstEncoder *encoder)
       encoder->gstenc = gst_bin_get_by_name(GST_BIN(encoder->pipeline), "encoder");
  +    GstElementFactory *factory = gst_element_get_factory(encoder->gstenc);
  +    const gchar *factory_name = factory ? gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory)) : "";
  +    encoder->gstenc_caps_are_dynamic = g_str_has_prefix(factory_name, "va") &&
  +                                       !g_str_has_prefix(factory_name, "vaapi");
  @@ static gboolean configure_pipeline(SpiceGstEncoder *encoder)
  +    if (!(encoder->set_pipeline & SPICE_GST_VIDEO_PIPELINE_STATE) &&
  +        encoder->gstenc_caps_are_dynamic) {
  +        if (encoder->set_pipeline & SPICE_GST_VIDEO_PIPELINE_BITRATE) {
  +            set_gstenc_bitrate(encoder);
  +        }
  +        if (encoder->set_pipeline & SPICE_GST_VIDEO_PIPELINE_CAPS) {
  +            set_appsrc_caps(encoder);
  +        }
  +        encoder->set_pipeline = 0;
  +        return TRUE;
  +    }
  ```

  (plus a `gboolean gstenc_caps_are_dynamic;` in `SpiceGstEncoder`).

The `va` plugin is one file, `libgstva.so`, in `gstreamer1.0-plugins-bad`; the
libraries it uses (`libgstreamer-plugins-bad1.0-0`, libva, gudev) are packaged
on their own, and the package below depends on them. We packaged that file
alone, from Debian's own package of the same version, instead of installing the
133 others:

```sh
apt-get download gstreamer1.0-plugins-bad      # on any trixie amd64 system
dpkg -x gstreamer1.0-plugins-bad_*.deb x
mkdir -p pkg/DEBIAN pkg/usr/lib/x86_64-linux-gnu/gstreamer-1.0
cp x/usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstva.so pkg/usr/lib/x86_64-linux-gnu/gstreamer-1.0/
cat > pkg/DEBIAN/control <<'END'
Package: gstreamer1.0-va-local
Version: 1.26.2-3+deb13u3~local1
Architecture: amd64
Maintainer: local build <root@localhost>
Depends: libgstreamer-plugins-bad1.0-0 (>= 1.26.2), libgstreamer-plugins-bad1.0-0 (<< 1.27), libva2, libva-drm2, libgudev-1.0-0, libdrm2
Conflicts: gstreamer1.0-plugins-bad
Description: GStreamer va plugin only (libgstva.so from gstreamer1.0-plugins-bad)
END
dpkg-deb --root-owner-group --build pkg gstreamer1.0-va-local.deb
```

(`gst-inspect-1.0 vah264lpenc`, from `gstreamer1.0-tools`, shows "VA-API H.264
Low Power Encoder" once it is installed.)

When Debian updates `gstreamer1.0-plugins-bad`, rebuild it from the new version.

With both patches on the page above: 3 encoder errors in 30 s, all as the stream
switched to H.264, instead of 30, and 29.4 fps against 22.4 with MJPEG
(click to screen: median 148 ms against 122). The client needs 0016 too: the
server's rate control lowered the bit rate report after report against the
margins SpiceMac reported before it, down to ~0.1 Mbit/s and 3 fps within a
minute; with it, 30 fps for minutes, also after changing Video Delay from 50 to
30 ms. And 0023 when sound plays with Sync Video to Audio off: the reports then
followed the audio's delay, and the rate control cut its bit rate limit from 74
to 15.6 Mbit/s in 6 minutes. And 0024 against Wi-Fi jitter: frames a few ms later
than usual lowered the limit, from 19.7 to 7.9 Mbit/s in a new stream's first 4 s,
while the server's first estimate of the guest's frame rate (12 fps for a video
at 29) asks for more margin than the client reports.

### Frames bigger than the stream

When the guest draws something next to the video in the same frame (a counter or
a progress bar under a player; on our test page, a line of text or a few rows
above the video), spice-server sends that frame as part of the stream at its
own, bigger size: a "sized" frame, in the protocol since 2012 for exactly this
case. The H.264 encoder restarts at every size change, to the bigger size and
back with the next frame, each time with a key frame. On our page that was two
key frames a second, ~82 KB each against ~16 KB for a normal frame: +28% of the
stream (3.9 to 5.0 Mbit/s), and more on less animated content, whose normal
frames are smaller. MJPEG, which encodes every frame on its own, is not
affected. (SpiceMac's decoder used to make a new session at each change too;
patch 0022 keeps the previous ones, which also helps against a stock server.)

A patch splits such frames, for encoders that restart on a size change: the
stream's area of the frame is encoded at the stream's size as a normal frame, and
the rest of the drawable, within its clip, goes out as images right after it,
before any later drawing. Anything unusual (scaling, a mask, a palette, more than
8 rectangles, an encoder refusing the frame) falls back to the sized frame. The
protocol does not change, and clients without the sized-frame capability, which
got the whole frame as a lossless image, get the split frame too. It is about 150
lines in `server/dcc-send.cpp`:
[spice-server/stream-split-sized.patch](spice-server/stream-split-sized.patch).
On our page, over 3.5 minutes: 217 frames split, the rest (1158×3 there) sent as
an 84-byte image each time, the encoder configured once, a single key frame. In
spice-server's own test (`server/tests/test-display-streaming.c`, whose sized mode
cannot be enabled from its command line), bands drawn in the extra area arrived
in place, also under a clip. Not tried yet: guests whose bitmaps are stored
bottom-up (the code handles them).

### Very thin streams

Windows sometimes draws strips of a video area on their own, 1158×4 or 1158×13,
and with `videostreaming=all` spice-server turns them into streams of their own.
`vah264lpenc` refuses frames below 32 pixels (1158×16 failed, 1158×32 worked):
the server built a pipeline, saw it fail, and tried three times per size, about
30 ms each on the thread that sends the whole display, and again at every size
change of the strip. A patch makes the encoder refuse such frames before building
anything; they go out as images, which is where they ended up anyway:

```diff
--- a/server/gstreamer-encoder.c
+++ b/server/gstreamer-encoder.c
+#define SPICE_GST_MIN_FRAME_SIZE 32
@@ spice_gst_encoder_configure_pipeline(SpiceGstEncoder *encoder,
     const SpiceFormatForGStreamer *format = GSTREAMER_FORMAT_INVALID;
 
+    if (width < SPICE_GST_MIN_FRAME_SIZE || height < SPICE_GST_MIN_FRAME_SIZE) {
+        return VIDEO_ENCODER_FRAME_UNSUPPORTED;
+    }
```

(The patch also logs the first such frame of a stream.) No thin strip turned up
in our runs since, so this one is checked only in that nothing else changed.

## Faster file copies

Files dropped on SpiceMac's window travel to the guest's agent in SPICE messages of
at most 2 KB. The server lets the client send 10 of them before it returns tokens,
5 at a time, once the agent's virtio-serial port has taken them: 20 KB per round
trip, ~1 MB/s. Both numbers date from the first public commit of the SPICE code
(2009), when the agent only carried mouse, clipboard and display settings; file
transfer came later and they were never revisited.

With the window at 64 and tokens returned 16 at a time (a patch in our package's
`debian/patches/`):

| File | Stock (10/5) | 64/16 |
|---|---|---|
| 20 MB | 18.7 s (1.1 MB/s) | 1.5 s (13 MB/s) |
| 200 MB | — | 18.8 s (10.6 MB/s) |

Both copies arrived intact (same SHA-256). The token accounting is the part of
spice-server that had bugs before (a crash and a client/server token mismatch, fixed
in 2016), so with 64/16 we also tried: cancelling a 100 MB copy halfway, then
copying another file; and restarting the guest's `spice-agent` service in the middle
of a 400 MB copy, then copying again. Each time the interrupted copy ended cleanly
(no partial file left in the guest), the client stayed connected, the agent came
back within 0.3 s and the next copy arrived intact. The server's receive buffer per
client grows from ~26 KB to ~137 KB. Not tried: live migration between nodes whose
spice-server use different windows (Proxmox migrates SPICE sessions seamlessly);
keep the nodes of a cluster on the same package.

```diff
--- a/server/main-channel.h
+++ b/server/main-channel.h
-#define REDS_AGENT_WINDOW_SIZE 10
+#define REDS_AGENT_WINDOW_SIZE 64
--- a/server/reds.cpp
+++ b/server/reds.cpp
-#define REDS_TOKENS_TO_SEND 5
+#define REDS_TOKENS_TO_SEND 16
```

## Going back

```sh
apt-get install --allow-downgrades libspice-server1=0.15.2-1+b1     # level 2
apt-get purge gstreamer1.0-va-local intel-media-va-driver           # level 3
apt-get purge gstreamer1.0-plugins-ugly                              # level 1
apt-get autoremove                                                   # their libraries
qm reboot <vmid>
```

Purge `gstreamer1.0-plugins-base` and `-good` too if they were installed only for
these levels, and `gstreamer1.0-vaapi` and `vainfo` if you installed them. Each VM
keeps the old libraries until its QEMU process restarts.
