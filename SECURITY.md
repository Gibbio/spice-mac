# Security

This documents SpiceMac's security posture, the threat model, what's hardened,
and the residual risks. It reflects a threat-model-driven audit (with adversarial
verification of every finding).

## Threat model

- **Network MITM** between the Mac and the Proxmox node — defended by TLS.
- **A malicious / compromised SPICE server or guest VM** sending hostile
  display / cursor / clipboard / agent data to the client.
- **A crafted `.vv` file** the user opens.
- **Local**: the `.vv` carries a short-lived ticket + CA; the app can run as root
  for USB; ad-hoc signing; the bundled native stack is built from pinned upstream sources.

## Overall posture

The app's own code (the Swift packages + the one-method ObjC fork patch) has **no
memory-corruption or RCE-class defects**: TLS verification fails closed in every
real Proxmox flow, the guest-data sizing/coordinate math is bounds-safe, and the
CA handling is memory-safe. The real risk is **supply-chain debt** (the EOL
sysroot is the sole TLS stack and the sole parser for all hostile-server data)
plus a few guest-triggered **denial-of-service** crashes and an **unsafe-by-
default** clipboard share. Solid for personal use against a **trusted** Proxmox
node; not hardened against a deliberately hostile guest, and the EOL stack should
gate any wider distribution.

## Hardened in this repo

- **Guest→host non-UTF8 clipboard crash (DoS)** — a guest could abort the client
  by sending non-UTF8 bytes labelled as text (nil trapped the Swift bridge). The
  delegate is now nullable and guards nil; guest payloads are size-capped.
- **Multi-head monitor-config crash (DoS)** — a protocol-legal multi-head config
  hit a `g_assert` and aborted the process, in two places: the per-surface area
  update (restored the upstream find-by-id loop) and the display create/update
  handler (`cs_display_monitors`, where the assert was simply removed). Never
  assert on attacker-controlled SPICE fields.
- **Writable host folder auto-shared to every guest** — removed; folder sharing
  should be opt-in and read-only (no UI yet → nothing shared).
- **Clipboard sharing is now a preference** (Connection ▸ Share Clipboard with VM,
  default on) so it can be disabled for untrusted VMs.
- **TLS fail-closed guard** — refuse to connect if a `.vv` requests
  certificate-subject verification but supplies no CA.
- **Hardened `.vv` parser** — the connection file is attacker-influenced, so the
  parser caps file size (1 MiB) + enforces UTF-8, strips control characters from
  values (a `NUL` would otherwise truncate the value inside the C SPICE stack),
  and range-checks ports. A deterministic 20k-iteration fuzzer + edge-case tests
  (`swift run vvcheck`) assert it never crashes on arbitrary input.
- **Pinned, fail-closed native build** — `scripts/build-deps.sh` builds the whole
  native stack from upstream sources pinned by URL + SHA-256 in `deps/sources.lock`
  and aborts on any mismatch. Meson may not fetch subprojects on its own, nothing may
  be found or linked from Homebrew, and a final check rejects any library that
  references a path outside `@rpath` or the OS. Patches on top of upstream live,
  reviewable, in `deps/patches/`.
- **Current OpenSSL, built natively** — OpenSSL 3.5 LTS (maintained to 2030) is built
  from source like the rest of the stack, and spice-gtk is compiled against it.

## Residual risks (not fixed in code)

1. **Native stack age — resolved by building from source.** Every native library is
   now a current upstream release (spice-gtk 0.43, glib 2.88, GStreamer 1.28,
   OpenSSL 3.5 LTS — see `deps/sources.lock`), replacing the UTM sysroot's glib ~2.69
   and GStreamer 1.19.1 development snapshot. What remains is keeping the pins
   current: bump a package in `deps/sources.lock` when upstream ships a security fix.

2. **Running as root for USB.** `scripts/run-as-root.sh` runs the *entire* app —
   including the SPICE/TLS/glib/gstreamer/clipboard/agent parsers that consume
   hostile-server data — as root, so any parser bug becomes root-impact. This is the
   **supported USB path** for an ad-hoc build; the script warns and confirms, and it
   is only needed to redirect a device a macOS kernel driver owns. **Mitigation
   today:** only run as root when you actually need such a device (driverless devices
   don't — see the README), and only against a VM/node you trust.

   **Why not a privileged helper (scoped + deferred).** macOS makes the clean
   "device-I/O-only helper that parses no network data" impossible: the bundled
   libusb can't hand a captured device to another process (`wrap_sys_device` is
   unsupported on Darwin, and IOKit device handles aren't transferable), so the
   privilege boundary must sit at the **usbredirhost seam** — the helper would host
   libusb **+ usbredirhost** and still parse guest-influenced usbredir bytes as root
   (a *partial* win; the TLS/display/clipboard/agent server-data parsers would leave
   root). It also requires forking spice-gtk and rebuilding the framework, plus a
   sudo-installed root LaunchDaemon with audit-token client auth (no Developer ID →
   SMAppService/SMJobBless are out). Given the cost vs. the partial win, it's
   deferred. The genuinely clean fix is the Apple-restricted
   `com.apple.vm.device-access` entitlement UTM uses (the bundled libusb already
   supports it), which needs a Developer ID — gated on the same signing/funding as
   notarization. Revisit if that lands.

3. **Distribution signing.** The default build is ad-hoc; the optional
   `HARDENED=1` entitlements include `com.apple.security.cs.disable-library-
   validation` (weakens dylib signing checks). For distribution: sign with
   **Developer ID + hardened runtime + notarization**, sign each bundled
   framework, and **drop `disable-library-validation`**.

4. **Clipboard is shared by default** (host↔guest). While on, anything copied on
   the Mac is sent to the guest. Disable it (Connection menu) for untrusted VMs.

## Verifying a downloaded build

Prebuilt release `.app`s are **ad-hoc signed**, **not Developer-ID-signed or
notarized** (residual risk 3). Ad-hoc signing gives the bundle a valid local code
signature but no identity Apple can attribute to a developer, so Gatekeeper warns on
first launch and the binary's provenance rests on this repo, not on Apple's
notarization. Notarization is gated on a paid Apple Developer membership (US$99/yr)
the project can't currently fund; sponsoring (the repo **Sponsor** button) would
change that.

To establish trust independently:

- **Rebuild from source** and run that instead of the download — the whole build is
  reproducible from this repo (README *Build*).
- **Compare the SHA-256.** Each release publishes `shasum -a 256` of the zipped
  `.app`; check your download matches **before** clearing quarantine.

Never clear quarantine on a build whose hash you haven't verified against the
release.

## Reporting

This is a personal/open-source project. For a suspected vulnerability, please
**report privately before public disclosure** via GitHub's
[private vulnerability reporting](https://github.com/Ching367436/spice-mac/security/advisories/new)
(Security ▸ Report a vulnerability), or contact the maintainer **Ching367436**
through [GitHub](https://github.com/Ching367436). For non-sensitive bugs, open a
regular issue. There is no formal SLA, but reports are reviewed as soon as
practical. Please don't include a live `.vv` ticket/CA in any report.
