<p align="center">
  <img src="design/icon/icon.png" width="168" height="168" alt="SpiceMac app icon">
</p>

# SpiceMac

A native macOS [SPICE](https://www.spice-space.org/) client that opens **Proxmox VE**
virtual-machine consoles from `.vv` connection files, built on a forked
[CocoaSpice](https://github.com/utmapp/CocoaSpice) (the Metal-rendered SPICE layer
UTM uses). Apple-Silicon only.

> **Status: working** against a real Proxmox VE VM (Xcode 27, native stack built
> from source by `scripts/build-deps.sh`). Verified end-to-end: Metal display with aspect-fit scaling and live
> resize; keyboard including ⌘/modifiers; mouse with the guest cursor aligned to
> the macOS pointer; bidirectional clipboard; and audio (needs a SPICE audio
> device on the VM). USB redirection is plumbed via the Connection menu. The `.vv`
> parser, keyboard map, and zoom geometry are also unit-tested (59 dependency-free
> checks).
>
> | Feature | Status |
> |---|---|
> | Display (Metal) + aspect-fit scaling + live resize | ✅ |
> | Keyboard incl. ⌘ / modifiers (self-healing on missed key-up) | ✅ |
> | Mouse + cursor alignment; optional hide-Mac-cursor | ✅ |
> | Clipboard (Mac↔VM, both directions) | ✅ |
> | Audio (guest needs a SPICE audio device) | ✅ native CoreAudio, 60–130 ms |
> | Microphone (off unless shared) | ✅ |
> | Copy files into the VM (drag and drop) | ✅ |
> | Several displays, a window each (Windows guest, `qxl2`–`qxl4`) | ✅ |
> | USB redirection | plumbed |

## Download

Prebuilt `SpiceMac.app` bundles are attached to each
[Release](https://github.com/Ching367436/spice-mac/releases) (Apple-Silicon only).
You can also [build from source](#build).

### Why it's unsigned

The prebuilt `.app` is **ad-hoc signed**, not **Developer-ID-signed or notarized**.
Developer-ID signing + notarization require a paid **Apple Developer Program**
membership (US$99/yr) this project can't currently fund. Ad-hoc signing is real and
locally valid — it's why the app runs at all on Apple Silicon — but macOS Gatekeeper
still treats the download as coming from an unidentified developer and prompts once
on first launch. If a signed + notarized build matters to you, you can help fund the
membership (see [Sponsoring](#sponsoring)) or just build from source.

### Opening an unsigned build

After unzipping and moving `SpiceMac.app` to `/Applications`, do one of:

- **macOS 14 (Sonoma):** right-click (Control-click) the app ▸ **Open** ▸ **Open**
  in the dialog (only needed once).
- **macOS 15 (Sequoia) and later:** double-click once (you'll see *"Apple could not
  verify…"* — click **Done**), then **System Settings ▸ Privacy & Security ▸ Open
  Anyway**, and confirm. (Sequoia removed the old right-click→Open shortcut here.)
- **Terminal (works on both)** — clear the quarantine flag, then open:

  ```sh
  xattr -dr com.apple.quarantine /Applications/SpiceMac.app
  open /Applications/SpiceMac.app
  ```

Verify your download against the SHA-256 in the release notes before clearing
quarantine:

```sh
shasum -a 256 SpiceMac.app.zip   # compare to the value in the Release
```

See [SECURITY.md](SECURITY.md) for the full signing/trust posture.

## Why this exists

There is no pleasant native SPICE client on macOS — `remote-viewer`/`spice-gtk`
builds are heavy, GTK/X11-bound, and sluggish. SpiceMac wraps the same mature
SPICE stack but renders through Metal in a small native app, and connects to
Proxmox the way the Proxmox web UI does: by consuming the short-lived `.vv` file.

## Architecture

```
AppKit + SwiftUI chrome           Sources/SpiceMac
        │   (MTKView host, .vv open, menus, USB picker, window mgmt)
        ▼
SpiceController (Swift)           Packages/SpiceController
        │   CSConnectionDelegate, NSEvent→CSInput, NSPasteboard bridge, lifecycle
        ▼
CocoaSpice (forked, Obj-C)        ThirdParty/CocoaSpice   ← Proxmox patch
        │   Metal renderer, channels, USB, clipboard over spice-client-glib
        ▼
Native SPICE stack (arm64)        Sysroot/  (built from source by scripts/build-deps.sh)
        spice-client-glib, glib, libusb, usbredir, openssl, …

Pure-Swift, independently testable:
  VVConfig        Packages/VVConfig       — virt-viewer .vv parser (+ Proxmox)
  SpiceInputMap   Packages/SpiceInputMap  — macOS keycode → PC set-1 scancode
  DisplayScale    Packages/DisplayScale   — zoom / viewport geometry (guest px ↔ points)
```

The decisive design point: **CocoaSpice must be forked.** `CSConnection` keeps the
underlying `SpiceSession` private, so the Proxmox knobs (`proxy`, `ca`,
`cert-subject`, subject-verify) can only be set from inside the library. The fork
adds exactly one method, `-[CSConnection setProxy:ca:certSubject:]`
(`ThirdParty/cocoaspice-proxmox.patch`, rationale in `ThirdParty/CocoaSpice/FORK-NOTES.md`).

## Requirements

- Apple Silicon Mac, macOS 12+.
- **Full Xcode** (build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
- The **Metal toolchain component** — on Xcode 26 it is a separate download:
  `xcodebuild -downloadComponent MetalToolchain`. Needed because SwiftPM does not
  compile `.metal` resources; `build-app.sh` compiles the shader into the bundle.
- Homebrew build tools: `brew install meson ninja cmake pkg-config` (see *Dependencies*).

## Build

**Prerequisites (one-time).** Full **Xcode** (Command Line Tools alone can't build
this), then select it and add the Metal toolchain component:

```sh
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -downloadComponent MetalToolchain   # Xcode 26: a separate download
```

Then, from a fresh clone:

```sh
make doctor   # verify Xcode + Metal toolchain + build tools (prints fixes if not)
make all      # build the native stack from source, then the app → build/SpiceMac.app
make run      # open it
```

`make` wraps the scripts in `scripts/` and injects `DEVELOPER_DIR` so you can't
forget it (`make help` lists every target). By hand it's:

```sh
./scripts/build-deps.sh      # native stack from pinned, checksummed sources → Sysroot/
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh
open build/SpiceMac.app
```

### Dependencies

CocoaSpice does **not** bundle the native libraries it links (glib,
spice-client-glib, libusb, …). `scripts/build-deps.sh` builds them from upstream
sources into `Sysroot/` (arm64, macOS 12+, every library `@rpath`-relative):

- **Pinned and fail-closed.** `deps/sources.lock` fixes each package's version, URL
  and SHA-256; a mismatch aborts the build. Meson may not fetch subprojects on its
  own, and nothing may be found or linked from `/opt/homebrew` — Homebrew's meson,
  ninja, cmake and pkg-config are used only as tools. A final check rejects
  any library that references a path outside `@rpath` or the OS.
- **Patched where needed.** `deps/patches/<package>/` holds the patches applied on
  top of upstream. For spice-gtk: UTM's GMainContext support (CocoaSpice relies on
  it), a macOS build fix, the VideoToolbox H.264 decoder, our video timing
  fixes and what the menu and statistics need — see [deps/README.md](deps/README.md).
- **No GPL.** LGPL / Apache-2.0 / BSD / MIT / ISC only — see
  [THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt).

A first build takes a few minutes; later runs only rebuild what changed
(`./scripts/build-deps.sh <package>` forces one, `--clean` starts over). CocoaSpice
compiles against the headers installed into `Sysroot/`, so they always match the
libraries.

### Updating a dependency

Every version is one line in `deps/sources.lock`. Edit it — a new version + URL for a
release (the build stops and prints the new SHA-256 to verify and paste in), or a new
commit id for the SPICE projects, which are followed from git because they tag
releases rarely (`git ls-remote <url> <branch>`) — then `./scripts/build-deps.sh`
rebuilds just what changed. If one of our patches no longer applies, see
[deps/README.md](deps/README.md).

## Connecting to Proxmox

1. In the Proxmox web UI, open a VM whose **Display is set to SPICE/qxl**
   (`qm set <vmid> --vga qxl`), click **Console ▸ SPICE**, and download the
   `.vv` file.
2. Open it in SpiceMac (double-click, drag onto the app, or **File ▸ Open**).
   **Do this promptly** — the SPICE ticket inside is single-use and valid for only
   ~30 seconds. To reconnect, download a fresh `.vv`.
3. For clipboard sharing and dynamic resolution, the guest must run
   **`spice-vdagent`**.

What the app does with the `.vv`: parses the opaque `host` token, `proxy`
(`http://node:3128`), `tls-port`, one-time `password`, `host-subject`, and CA
(expanding the escaped `\n`), then connects over TLS through the node's
`spiceproxy`, verifying the server by **certificate subject** against the supplied
CA.

## Video streaming

SPICE sends video as a compressed **stream** only when the server is told to, and
only when it can see the video as one region:

- **Display: `qxl`**, not `virtio`. With `virtio` (and other non-QXL displays) QEMU
  reports screen updates as 32-pixel-wide column strips, which the server never
  recognises as video: every frame then arrives as dozens of lossless images.
- **Streaming on:** `qm set <vmid> --spice_enhancements videostreaming=all` (or
  `filter`). Without it QEMU turns streaming **off**.

Streams arrive as MJPEG by default. SpiceMac can also decode **H.264** in hardware
(VideoToolbox) — in our 720p30 test (debug logging on) ~11% of a core against ~26%
for MJPEG. Turn it on with **Connection ▸ Prefer H.264 Video**, which applies at
once (`SPICE_PREFERRED_VIDEO_CODECS=h264,mjpeg` at launch overrides it). It is
off by default because the work moves to the node: Proxmox's spice-server
encodes H.264 in software (x264, from
`gstreamer1.0-plugins-ugly`, not installed by default), about a third of a core
per stream in our tests against 5–9% for MJPEG.
[docs/server-side-video.md](docs/server-side-video.md) describes what the node
needs, up to spice-server 0.16 with Intel Quick Sync: 30 fps at ~3 Mbit/s for ~7%
of a core.

**Latency.** The server keeps the client's clock 400 ms behind its own, as room to
line video up with buffered audio. Unless the guest is playing sound, SpiceMac
shows each frame about 50 ms after it arrives instead. Measured with a headless
client on the same SPICE library (LAN, Windows 11 guest, MJPEG, 1280×720), a
click reached the client's framebuffer in a median 154 ms, against ~500 ms stock.
**Connection ▸ Video Delay** trades latency for room for network jitter: 30 ms
(median 128 ms in that test), 50 ms (the default) or 80 ms (185 ms).
`SPICE_STREAM_PLAYOUT_MS` at launch overrides it, and `0` restores the stock
behaviour.
Sounds shorter than a few seconds, such as notifications, leave the video's timing
alone. Longer ones hand the video back to the server's timing, lined up with the
audio: some 3–4 s into the sound, after a single pause of about the audio's delay.
With the CoreAudio output (below) that is 60–130 ms: a continuous tone in the
guest had video shown 69 ms after arrival, against 225 ms with the GStreamer output
SpiceMac used before.

**Statistics.** **View ▸ Show Statistics** (⌃⌘I) lays a panel over the display,
refreshed once a second:

- **Network:** bandwidth received, total and by channel; the TCP round trip (to
  the node's spiceproxy); the TLS version and cipher.
- **Display:** the guest resolution, mouse mode and agent; how many frames the
  Mac draws per second and how long an uploaded frame takes to reach the screen.
- **Video:** each stream's codec, decoder (VideoToolbox or the built-in MJPEG one)
  and size; frames per second received and shown; frames late and
  dropped; how long after arrival frames are shown, and which clock they follow.
- **Audio:** the codec (Opus or raw), whether it plays, the output delay (buffer
  plus device), underruns and skipped audio; whether the microphone is shared and
  whether the VM is trying to record.

It answers "is this H.264?" and "is it the network or the server?" at a glance.
The time from the guest to the client is not in it: the server's timestamps do
not tell it.

## Audio

Sound plays through CoreAudio directly (a spice-gtk backend of ours, patch 0013):

- **60–130 ms behind the guest instead of ~220 ms**, from a packet's arrival to
  the speaker. SpiceMac buffers 40 ms to start with (`SPICE_COREAUDIO_BUFFER_MS`)
  and tells the server the real delay: what is buffered plus the output device's
  latency (16 ms in our test).
- **The buffer adapts to the network.** Audio packets normally arrive every
  10–17 ms, but on the Mac's Wi-Fi the stream sometimes pauses for up to ~130 ms
  and then arrives at once (macOS's own Wi-Fi activity, such as AWDL for AirDrop,
  is the likely cause). So the buffer grows to cover any pause that comes near it,
  and shrinks by 10 ms after every 5 calm minutes. Over 15 min of continuous sound
  on Wi-Fi: two dropouts in the first minute, none after, with the delay around
  120 ms; a fixed 40 ms buffer had 11 dropouts in 18 min. Without such pauses it
  stays at the 40 ms it starts from, ~60 ms in all. Audio that stays buffered
  beyond the target for a whole second is skipped, so the delay does not creep up
  over a long session.
- **It plays through the system's default output unit**, which moves to whatever
  output device macOS switches to (headphones, AirPods) on its own.
- **Microphone: off by default.** A guest can start recording whenever it likes,
  and nothing would tell you, so **Connection ▸ Share Microphone with VM** has to
  be turned on first (it applies at once; macOS asks the first time). Off, the VM
  gets no sound when it records; View ▸ Show Statistics shows when it tries.

## Copying files into the VM

Drag files from the Finder onto the window: the guest's SPICE agent saves them
(spice-vdagent on Windows puts them on the Desktop). A bar at the top of the display
shows what is being copied, how much is done, the speed and the time left, with a
button to stop; then how it went. Folders are not copied (the agent protocol carries
files only): drop the files in them, or a `.zip`. Nothing in the guest is
overwritten: when the name is taken, spice-vdagent saves the copy as `name (1).ext`,
`name (2).ext`… The protocol cannot ask whether a file exists, nor say under which
name it was saved, so SpiceMac cannot ask before or tell after.

It needs the guest agent, and with a stock spice-server it is slow: the agent
protocol carries 2 KB per message and the server lets 10 of them travel at a time,
so it runs at about 1 MB/s (20 MB in 19 s in our test, the file arriving intact),
whatever the network. Raising that window on the node made it ~10× faster (200 MB
in 19 s): see [docs/server-side-video.md](docs/server-side-video.md) ▸ *Faster file
copies*.

## Multiple displays

Give the VM more than one display in Proxmox (Hardware ▸ Display ▸ *SPICE dual
monitor*, i.e. `vga: qxl2`; `qxl3` and `qxl4` for three and four) and SpiceMac opens
a window for each display the guest has on, on a screen of its own while there are
screens without a SpiceMac window, cascaded otherwise. Each window has its own
size, zoom and full screen, and the guest follows each window's size; in the guest
the displays sit side by side, left to right in order. The pointer goes to the
display under it; the keyboard to whichever window is in front. A `.vv` that asks
for full screen puts every window in full screen. View ▸ Displays lists the
displays: one that is off can be turned on there (it needs the guest agent), at
the main window's size.

Closing a display window other than the first only hides it; View ▸ Displays
shows it again, and closing the first window ends the session. SpiceMac never
turns a display off: when spice-vdagent-win (0.10, the current one) turns off a
display of a VM with several QXL devices, it cannot turn it back on until the
guest restarts, and until then every resolution change fails, the other displays'
included. Turning a display off from inside Windows (Win+P) is fine but SpiceMac
does not see it, so its window keeps the last picture and the next resize turns
the display on again.

This is for Windows guests, where Proxmox gives each display its own QXL device.
A Linux guest gets one QXL device with several heads, which SpiceMac does not
split into windows: it shows the first, and its first resolution request turns
the other heads off, as before.

## Verifying the tested components

The pure-Swift libraries build and test with just the Swift toolchain (no Xcode):

```sh
( cd Packages/VVConfig      && swift run vvcheck )     # .vv parser: 24 checks
( cd Packages/SpiceInputMap && swift run inputcheck )  # scancode map: 14 checks
( cd Packages/DisplayScale  && swift run scalecheck )  # zoom geometry: 21 checks
```

The CocoaSpice fork patch was syntax-checked against the real vendored
glib/spice headers (`clang -fsyntax-only`, exit 0).

## Gotchas

- **Ticket lifetime / opaque host.** The `.vv` ticket lasts ~30 s and is
  single-use; `host` is a `pvespiceproxy:…` token, not a hostname — the connection
  *must* go through `proxy=…:3128`. Re-download for every (re)connect.
- **Inverted TLS verification.** Trust the self-signed PVE cluster CA and match
  `cert-subject`; normal hostname/pubkey checks fail by design.
- **Guest agent required** for clipboard + dynamic resolution — including **View ▸
  Zoom**, which works by asking the guest for a different resolution. Without
  `spice-vdagent` the guest resolution is fixed, so zoom resizes the *window* instead.
- **Audio needs a SPICE audio device on the VM** — most Proxmox VMs ship without
  one, so there's no playback channel. Add **Hardware ▸ Audio Device** (e.g.
  `ich9-intel-hda`, backend **SPICE**) and reboot the guest.
- **`pveproxy` gating.** `/etc/default/pveproxy` `ALLOW_FROM`/cipher rules can
  reset port 3128 even with a valid ticket.
- **Dep ages.** Every native library is built from a current upstream release pinned
  in `deps/sources.lock` (spice-gtk 0.43, glib 2.88, OpenSSL 3.5 LTS);
  bump them there.

## Display zoom (Retina)

**View ▸ Zoom** sets how many Mac physical pixels each guest pixel occupies.

SpiceMac asks the guest agent for a resolution of `window points × backing scale ÷
zoom`. At **200%** on a Retina Mac the guest renders a quarter of the pixels and each
one is drawn as a crisp 2×2 block (nearest-neighbour kicks in automatically at
whole-number zoom) — readable guest UI *and* markedly less work for the VM, the host,
and the wire.

The default is **Automatic**, i.e. zoom = the screen's backing scale, so the guest
resolution simply tracks the window's *point* size: 2× on the built-in Retina display,
1× on a normal-DPI external monitor, adjusting itself when you drag the window between
them. Pick **100%** for the old behaviour (guest resolution = full backing pixels;
correct, but tiny on Retina).

**The level is per window.** Each window is its own session on its own display, so
setting a level in one leaves the others alone, and the Zoom menu always shows the front
window's level. A newly opened window starts at whatever level you last picked.

**A fixed level is absolute** — Z host pixels per guest pixel wherever the window is —
and nothing but you ever changes it. Drag a 100% window onto the Retina panel and it
stays at 100%; the guest reconfigures and its UI gets smaller, because that is what 100%
means there. If you want the apparent size to stay constant across a move, that is what
**Automatic** is for.

Shortcuts are ⌃⌘+ / ⌃⌘− / ⌃⌘0 (zoom in / out / Automatic) rather than plain ⌘±, so
⌘+ and ⌘− keep reaching the guest as Super-plus / Super-minus.

Guest text is pixel-exact at any whole-number zoom, 1:1 included. The one case that stays
soft is a guest that refuses the requested mode and picks a *larger* one from its own mode
table: the picture then has to be downscaled to fit the window, and downscaling has to
stay bilinear or it aliases badly.

## USB redirection

USB redirect is available under **Connection ▸ USB Devices**, but macOS gates it:
`LIBUSB_ERROR_ACCESS` ("could not claim interface") means a **built-in kernel
driver already owns the device**. macOS auto-binds drivers to mass storage, HID
(keyboards/mice), USB audio, serial/CDC, iOS devices and hubs, and the device
must be *captured* away from that driver to redirect it — which requires one of:

- **Root** — the supported, entitlement-free path on a personal/ad-hoc build. Launch
  via `./scripts/run-as-root.sh <file>.vv` (the bundled libusb supports macOS device
  capture). The script warns and asks for confirmation (`-y` to skip).
  ⚠️ It runs the **whole app** as root — including the parsers that read data from
  the SPICE server — so use it only against a VM/node you **trust**, and only when
  you actually need a kernel-claimed device. Capture is whole-device; HID may not
  detach even as root. (A privileged helper that would keep the SPICE stack
  unprivileged was scoped and deferred — see [SECURITY.md](SECURITY.md).)
- **`com.apple.vm.device-access`** — an Apple-*restricted* entitlement (needs a
  provisioning profile + Apple approval and Developer ID signing; **ad-hoc
  signatures can't carry it**). This is what UTM's official builds use, and the
  genuinely clean fix — gated on the same Developer ID as notarization.

`com.apple.security.device.usb` and Hardened Runtime do **not** help (sandbox-only
/ no-op). **Driverless devices** (vendor-specific class `0xFF`, FTDI on macOS 12+,
many JTAG/printer dongles) redirect **without root** — check with
`ioreg -p IOUSB -l | grep IOUSBHostInterface` (no class-driver client bound → OK).

## Security

See [SECURITY.md](SECURITY.md). In short: the app code is sound (no RCE/memory-
corruption; TLS fails closed). The server-exposed native libraries are current —
every native library is built from a pinned, current upstream release (**spice-gtk
0.43**, **OpenSSL 3.5 LTS** (to 2030), glib 2.88 — see
`deps/sources.lock`). Clipboard sharing is on by default (toggle in the Connection menu),
and `run-as-root.sh` runs the whole parser surface as root — fine for personal use
against trusted VMs.

## Sponsoring

SpiceMac is free and open source. The one recurring cost it can't absorb is the
**Apple Developer Program** membership (US$99/yr) needed to ship Developer-ID-signed,
notarized builds that open without the Gatekeeper detour above. If you'd like to fund
that, use the repo's **Sponsor** button (see [`.github/FUNDING.yml`](.github/FUNDING.yml)),
or send ETH to **`ching367436.eth`**
([Etherscan](https://etherscan.io/address/ching367436.eth)). It's entirely optional —
building from source, and rebuilding to verify a download, will always stay free.

## Licensing

- SpiceMac's own code: **MIT** (see [LICENSE](LICENSE)).
- `ThirdParty/CocoaSpice`: **Apache-2.0** (vendored fork; `LICENSE` retained, changes in
  [FORK-NOTES.md](ThirdParty/CocoaSpice/FORK-NOTES.md)).
- The native SPICE stack (built from source at build time, bundled into a built `.app`)
  is mostly **LGPL-2.1+** (glib/spice-gtk/libusb/usbredir/…), with **OpenSSL**
  (Apache-2.0) and **MIT/BSD/ISC** (pixman, opus, libffi, libjpeg-turbo, PCRE2,
  libucontext). Full attribution +
  the LGPL written offer: [THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt).
- The LGPL libraries are dynamically linked. The build bundles only the runtime
  closure, and no GPL component is built at all.
- **Distributing a built `.app`?** It already self-carries the verbatim LGPL-2.1 /
  Apache-2.0 / BSD / MIT / ISC texts at `Contents/Resources/Licenses/` (sources in
  [`licenses/`](licenses/)), plus the LGPL §6 written offer in
  [THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt). Honor those source/relink
  obligations when you redistribute.

## Layout

| Path | Purpose |
|------|---------|
| `Packages/VVConfig` | `.vv` parser + `SpiceConnectionParameters` (tested) |
| `Packages/SpiceInputMap` | keycode → set-1 scancode map (tested) |
| `Packages/SpiceController` | connection lifecycle, input/clipboard glue |
| `Sources/SpiceMac` | AppKit/Metal application |
| `ThirdParty/CocoaSpice` | vendored Apache-2.0 fork + Proxmox patch |
| `deps/` | pinned native sources (`sources.lock`) + patches |
| `Sysroot/` | native SPICE stack built by `build-deps.sh` (git-ignored) |
| `Makefile` | task runner over `scripts/` (`make help`) |

### Scripts (`scripts/` — or use the `make` target)

| Script | `make` | When you'd run it |
|--------|--------|-------------------|
| `doctor.sh` | `doctor` | Check the build environment (Xcode, Metal toolchain, build tools, Sysroot) |
| `build-deps.sh` | `setup` | Build the native SPICE stack from pinned sources into `Sysroot/` |
| `build-app.sh` | `build` | Build + assemble `build/SpiceMac.app` |
| `make-icon.sh` | `icon` | Regenerate `Resources/AppIcon.icns` from `design/icon/` |
| `debug-run.sh` | `debug VV=…` | Launch with verbose SPICE/CocoaSpice tracing |
| `run-as-root.sh` | `root VV=…` | Launch as root for USB capture (kernel-claimed devices) |
| `release.sh` | `release VERSION=…` | Cut a release (bump, changelog, build, tag, publish) |
| `check-version.sh` | `check-version` | Assert Info.plist / CHANGELOG / tag versions agree |
