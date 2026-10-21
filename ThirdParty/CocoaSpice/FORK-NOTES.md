# Vendored fork of utmapp/CocoaSpice

This directory is a vendored copy of [utmapp/CocoaSpice](https://github.com/utmapp/CocoaSpice)
(Apache License 2.0 — see `LICENSE`), the Objective-C/Metal SPICE client layer that
UTM uses, with a single addition for **spice-mac**.

## Why a fork is required

`CSConnection` keeps the underlying `SpiceSession *` private (declared only in the
in-`.m` class extension and in `CSSession+Protected.h`, neither of which is public).
Proxmox VE serves SPICE over TLS through the node's `spiceproxy`, which requires the
session be configured with `proxy`, `ca`, `cert-subject`, and subject-based `verify`
— none of which stock CocoaSpice exposes. So the configuration must happen *inside*
the library, where `spiceSession` is reachable.

## The change

A single category method, `-[CSConnection setProxy:ca:certSubject:]`:

- **`Sources/CocoaSpice/include/CSConnection+Proxmox.h`** — new public header (category interface).
- **`Sources/CocoaSpice/CSConnection.m`** — imports the header and implements the method
  (sets `proxy`, the `ca` GByteArray, `cert-subject`, and `verify = SPICE_SESSION_VERIFY_SUBJECT`).
- **`Sources/CocoaSpice/include/CocoaSpice.h`** — includes the new header in the umbrella.

The diff against pristine upstream is saved at `../cocoaspice-proxmox.patch`.

## Security hardening (spice-mac additions)

Beyond the Proxmox patch and the `CocoaSpiceRenderer` product, this fork carries a
few security fixes for guest-triggered crashes / unsafe defaults. Re-apply these
on a rebase:

- **`Sources/CocoaSpice/CSDisplay.m`** (`cs_update_monitor_area`) — replaced
  `g_assert(monitors->len <= 1)` (which aborts the process on a protocol-legal
  multi-head config — a remote DoS) with the upstream find-our-head-by-id loop.
- **`Sources/CocoaSpice/CSConnection.m`** (`cs_display_monitors`) — removed
  `g_assert(cfgs->len == 1)` (same DoS class: a multi-head monitors config from
  a malicious/multi-monitor guest aborted the whole client). The handler only
  needs to know whether the display has any heads (create/update) or none
  (destroy); per-head geometry is resolved by `cs_update_monitor_area`.
- **`Sources/CocoaSpice/include/CSPasteboardDelegate.h`** — `setString:` made
  `nullable` so a guest sending non-UTF8 "text" (→ nil NSString) can't trap the
  Swift bridge.
- **`Sources/CocoaSpice/CSSession.m`** (`initWithSession:`) — removed the
  unconditional `setSharedDirectory:readOnly:NO`, which auto-shared a **writable**
  host folder with every guest.

## Bug fixes (spice-mac additions)

- **`Sources/CocoaSpice/CSDisplay.m` + `CSDisplay+Renderer.m`** — **blank screen on
  connect** (shown only after the guest next repaints, e.g. a click). Two parts:
  - The SPICE main loop runs on its own thread (`CSMain`). A display's primary
    surface is created there (`cs_primary_create` → `updateVisibleAreaWithRect:` →
    `rebuildCanvasTexture`), but the Metal **device** only arrives when a renderer
    attaches — from the app thread, via `-addRenderer:`. On connect the surface is
    usually created *before* the renderer attaches, so `rebuildCanvasTexture`
    early-returns on the nil device and there is no Metal canvas; the renderer then
    draws nothing until a later server damage event. Fix: `-addRenderer:` calls the
    new `-refreshContentsForNewRenderer`, which hops to the SPICE context and, with
    a device now available, builds the canvas (if not yet built) and repaints the
    current framebuffer.
  - In `updateVisibleAreaWithRect:`, build the vertices and set `ready` *before*
    `rebuildCanvasTexture`, so its initial `drawRegion:` sees `-isVisible` YES
    (`_CSRendererSourceData initWithRenderSource:` returns nil when vertices are
    missing, which otherwise drops the first blit) — this covers the case where a
    renderer/device *is* already attached when the surface is (re)created.
- **`Sources/CocoaSpice/CSSession.m`** (`cs_clipboard_grab`) — **guest→host
  clipboard lost all but one representation.** A guest grab is a single clipboard
  offering that can carry several types at once (a copied spreadsheet cell =
  UTF8 text + a bitmap image); CocoaSpice requests every advertised type, and each
  arrives in a separate `cs_clipboard_got_from_guest` call. The macOS pasteboard
  bridge cleared the pasteboard on *every* write, so the types clobbered each other
  and only the last survived (often the image) — pasting the cell's text on the Mac
  got nothing. Fix: `cs_clipboard_grab` now takes ownership of the host pasteboard
  **once** (`[pasteboardDelegate clearContents]`) when the grab arrives, and the
  bridge's `setData:`/`setString:` no longer clear per write, so the representations
  accumulate. (Pairs with the bridge change in
  `Packages/SpiceController/Sources/SpiceController/SpicePasteboardBridge.swift`.)
- **`Sources/CocoaSpiceRenderer/CSMetalRenderer.m`** (`drawInMTKView:`) — checks
  whether there is anything new to draw *before* touching `currentRenderPassDescriptor`
  / `currentDrawable`: either one acquires a drawable, so an idle display acquired
  one on every vsync for nothing. `mtkView:drawableSizeWillChange:` now sets
  `renderNeedsUpdate`, so a resize redraws a still guest screen at the new size
  (upstream's 843d652 made drawing on-change only, and a resize is not a change).

## Diagnostics (spice-mac additions)

With `SPICE_DEBUG` set, the time from a frame reaching CocoaSpice to the screen is
logged once a second, in two parts:

- **`Sources/CocoaSpice/CSDisplay.m`** (`recordUploadWait`) — `upload wait`: from the
  invalidate to the upload, i.e. how long a change waits in `canvasDirtyRect` while
  the previous frame is still being drawn (`canvasIsBusy`).
- **`Sources/CocoaSpiceRenderer/CSMetalRenderer.m`** (`_recordPresentLatency:`) —
  `present`: from the upload to the drawable's `presentedTime`.

## Video settings and statistics (spice-mac additions)

For SpiceMac's Connection ▸ Prefer H.264 Video / Video Delay and View ▸ Show
Statistics, on top of spice-gtk patches 0010 (the codec preference is held until
the server's first MARK) and 0012 (the playout setter and the statistics getters):

- **`Sources/CocoaSpice/include/CSConnection+Streaming.h`** (in the umbrella
  header), implemented in **`CSConnection.m`** — `preferredVideoCodecs` and
  `streamPlayoutDelay`, applied to each display channel when it opens
  (`cs_display_channel_event`) and at once to the open ones;
  `-readStatisticsWithCompletion:` collects on the SPICE thread the bytes received
  per channel type, the main channel's TCP round trip (`TCP_CONNECTION_INFO`), TLS
  version and cipher and mouse mode, the playback channel's codec and delay, and
  every display's stream statistics.
- **`Sources/CocoaSpiceRenderer/CSMetalRenderer.m`** — `collectsPresentStatistics`
  turns the upload-to-screen measurement on without SPICE_DEBUG, and
  `presentedFrameCount` / `missedFrameCount` / `presentLatencySum` expose running
  totals; the once-a-second log stays SPICE_DEBUG only.

## Build integration (spice-mac additions)

- **`Package.swift`** — compiles against the headers `scripts/build-deps.sh` installs
  into `<spice-mac>/Sysroot` (the same build the app links) instead of the vendored
  `Sources/CocoaSpice/ExternalHeaders/`, which no longer matches the libraries
  (spice-gtk 0.43, glib 2.88, GStreamer 1.28) and is unused.
- **`Sources/CocoaSpice/gst_ios_init.m`** — GStreamer 1.22 merged the `videoconvert`
  and `videoscale` plugins into `videoconvertscale`; declare/register that instead.
- CocoaSpice relies on `spice_util_set_main_context()` from UTM's spice-gtk patches;
  their port to 0.43 lives in `deps/patches/spice-gtk/`.

## Upstream base

Vendored from utmapp/CocoaSpice **d8d29fc** (2026-09-22, "port: keep written data
alive until SPICE sends it"); originally imported at 52b1535 (2026-02-27) and
re-based onto d8d29fc on 2026-10-20 without conflicts. That brought in, among
others, the per-iteration autorelease pool in `CSMain.m` (Objective-C objects
created by SPICE callbacks were never released on the long-lived SPICE thread)
and the `CSPort` write-buffer lifetime fix.

## Updating upstream

To re-base onto a newer CocoaSpice: in a clone of utmapp/CocoaSpice, check out the
base commit above, copy this directory over it and commit ("spice-mac fork
changes") — that commit is exactly our delta — then `git rebase` it onto the new
upstream commit, review conflicts against the notes above, copy the result back
and update the base commit here.
The patch is intentionally tiny and is a good candidate to upstream as a PR.
