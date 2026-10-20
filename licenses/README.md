# Verbatim license texts

This directory holds the full, verbatim license texts for the third-party
components SpiceMac bundles into a built `SpiceMac.app`. They are copied into the
app at `Contents/Resources/Licenses/` by `scripts/build-app.sh`, so the required
notices travel **with** any distributed binary.

| File | Covers |
|------|--------|
| `LGPL-2.1.txt` | glib, gobject, gio, gmodule, spice-client-glib (spice-gtk), the GStreamer libraries + statically-linked base/good plugins, json-glib, libusb, usbredirhost, usbredirparser, proxy-libintl (LGPL-2.0-or-later, used under 2.1) |
| `Apache-2.0.txt` | CocoaSpice (vendored fork), OpenSSL 3.5 (libssl, libcrypto) |
| `BSD-3-Clause.txt` | opus, libjpeg-turbo, PCRE2 |
| `MIT.txt` | pixman, libffi |
| `ISC.txt` | libucontext |

Attribution, SPDX identifiers, exact versions, and the LGPL §6 source offer are in
[`../THIRD-PARTY-LICENSES.txt`](../THIRD-PARTY-LICENSES.txt). SpiceMac's own code is
MIT ([`../LICENSE`](../LICENSE)).
