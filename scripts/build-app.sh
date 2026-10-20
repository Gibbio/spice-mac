#!/usr/bin/env bash
#
# build-app.sh — build SpiceMac via SwiftPM and assemble a runnable SpiceMac.app.
#
# Requirements:
#   * Full Xcode (the Metal toolchain compiles CocoaSpice's shader; Command Line
#     Tools alone cannot build the app).
#   * The native SPICE stack built into ./Sysroot (run scripts/build-deps.sh).
#
# Environment overrides:
#   CONFIG=release|debug            (default: release)
#   SIGN_IDENTITY="Developer ID Application: …"   (default: "-" ad-hoc)
#   HARDENED=1                      sign with hardened runtime + entitlements
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP_NAME="SpiceMac"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\033[1;34m[build-app]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build-app] error:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preconditions (fail fast — don't produce a broken app) ----------------
# Full Xcode must be selected (Command Line Tools alone can't build this).
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    die "full Xcode is not selected (got: $(xcode-select -p 2>/dev/null)).
         Fix: sudo xcode-select -s /Applications/Xcode.app   (or run scripts/doctor.sh)"
fi
# The Metal toolchain (a separate component on Xcode 26) compiles CocoaSpice's
# shader. If it's missing the app builds but the display never renders — so fail
# HERE rather than ship a silently-broken bundle. Override with ALLOW_NO_METAL=1.
if [ "${ALLOW_NO_METAL:-0}" != "1" ] && ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    die "the Metal toolchain is not installed (xcrun metal failed).
         Fix: xcodebuild -downloadComponent MetalToolchain
         (or set ALLOW_NO_METAL=1 to build a non-rendering app anyway)"
fi

shopt -s nullglob
SYSROOT_LIB="$ROOT/Sysroot/lib"
[ -f "$SYSROOT_LIB/libspice-client-glib-2.0.dylib" ] \
    || die "Sysroot/ not built — run scripts/build-deps.sh first."

# --- Build -----------------------------------------------------------------
log "swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
[ -x "$BIN_PATH/$APP_NAME" ] || die "built executable not found at $BIN_PATH/$APP_NAME"

# --- Assemble .app ---------------------------------------------------------
log "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_PATH/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# App icon (CFBundleIconFile=AppIcon). Regenerate with scripts/make-icon.sh.
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundles (e.g. the compiled Metal shader for the renderer).
# SwiftPM resource bundles go in Contents/Resources (CocoaSpice's renderer loads
# CocoaSpice_CocoaSpiceRenderer.bundle from mainBundle.resourceURL).
for bundle in "$BIN_PATH"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# SwiftPM does NOT compile .metal resources (only Xcode's build system does), so
# compile the CocoaSpice shader into default.metallib inside the renderer bundle —
# newDefaultLibraryWithBundle: needs it, or the display cannot render.
RENDERER_DIR="$ROOT/ThirdParty/CocoaSpice/Sources/CocoaSpiceRenderer"
RES_BUNDLE="$APP/Contents/Resources/CocoaSpice_CocoaSpiceRenderer.bundle"
# Newer SwiftPM (the Swift Build backend, Xcode 27+) emits a macOS-layout bundle
# (Contents/Info.plist + Contents/Resources/) and already compiles the shader; older
# SwiftPM emits a flat bundle holding the raw .metal. Write into whichever layout we
# got — files at the root of a Contents/-layout bundle are unsealed and codesign
# refuses to sign it.
RES_DIR="$RES_BUNDLE"
[ -d "$RES_BUNDLE/Contents" ] && RES_DIR="$RES_BUNDLE/Contents/Resources"
if [ -f "$RENDERER_DIR/CSShaders.metal" ] && [ -d "$RES_BUNDLE" ]; then
    log "compiling Metal shader → default.metallib"
    mkdir -p "$RES_DIR"
    if xcrun -sdk macosx metal -I "$RENDERER_DIR" -c "$RENDERER_DIR/CSShaders.metal" -o "$WORK/CSShaders.air" 2>"$WORK/metal.log" \
       && xcrun -sdk macosx metallib "$WORK/CSShaders.air" -o "$RES_DIR/default.metallib" 2>>"$WORK/metal.log"; then
        rm -f "$RES_DIR/CSShaders.metal"        # raw source not needed at runtime
        # Minimal Info.plist so it is a valid, signable bundle (SwiftPM's own, if any, wins).
        [ -f "$RES_BUNDLE/Contents/Info.plist" ] || cat > "$RES_BUNDLE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.spicemac.CocoaSpiceRenderer.resources</string>
  <key>CFBundleName</key><string>CocoaSpiceRenderer</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
        log "  default.metallib OK"
    elif [ "${ALLOW_NO_METAL:-0}" = "1" ]; then
        log "WARNING: Metal shader compile failed but ALLOW_NO_METAL=1 — display will NOT render."
        sed 's/^/         metal: /' "$WORK/metal.log" 2>/dev/null | tail -2
    else
        sed 's/^/         metal: /' "$WORK/metal.log" 2>/dev/null | tail -3 >&2
        die "Metal shader compile failed — the app would not render the display.
         Fix: xcodebuild -downloadComponent MetalToolchain   (or ALLOW_NO_METAL=1 to ship a non-rendering app)"
    fi
else
    log "WARNING: renderer shader not found; display rendering may not work"
fi

# Native SPICE libraries — exactly the runtime closure: every @rpath dylib the
# executable loads, followed recursively through the libraries themselves. Anything
# in Sysroot/ that nothing loads (build-time tools, static archives) stays out, so
# what ships is what runs. Each is copied under its install name (the soname).
log "embedding the native library closure"
queue=("$APP/Contents/MacOS/$APP_NAME")
while [ ${#queue[@]} -gt 0 ]; do
    image="${queue[0]}"; queue=("${queue[@]:1}")
    for dep in $(otool -L "$image" | awk 'NR > 1 && $1 ~ /^@rpath\// { print substr($1, 8) }'); do
        [ -e "$APP/Contents/Frameworks/$dep" ] && continue
        [ -e "$SYSROOT_LIB/$dep" ] || die "missing runtime library: $dep (re-run build-deps.sh)"
        cp -L "$SYSROOT_LIB/$dep" "$APP/Contents/Frameworks/$dep"
        queue+=("$APP/Contents/Frameworks/$dep")
    done
done
log "  $(ls "$APP/Contents/Frameworks" | wc -l | tr -d ' ') libraries"

# --- License notices -------------------------------------------------------
# A distributed binary must carry the LGPL-2.1/Apache-2.0/OpenSSL/BSD/MIT texts and
# attribution WITH the .app (LGPL-2.1 §6/§1, Apache-2.0 §4(a), OpenSSL/BSD/MIT
# binary-redistribution clauses). Ship the verbatim texts + attribution in-bundle.
log "bundling license notices"
LIC_DST="$APP/Contents/Resources/Licenses"
mkdir -p "$LIC_DST"
cp "$ROOT/licenses/"*.txt "$LIC_DST/"
cp "$ROOT/THIRD-PARTY-LICENSES.txt" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

# --- Strip build-host rpath ------------------------------------------------
# SwiftPM bakes an absolute Xcode toolchain LC_RPATH into the binary. It is unused
# at runtime (all libswift* resolve from the OS dyld shared cache via /usr/lib/swift),
# but it leaks a machine-specific path; drop it so the bundle is host-agnostic. The
# app is (re-)signed below, so this stays sealed.
XCODE_SWIFT_RPATH="$(otool -l "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null \
    | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' \
    | grep -m1 'Xcode.*Toolchains.*swift' || true)"
if [ -n "$XCODE_SWIFT_RPATH" ]; then
    install_name_tool -delete_rpath "$XCODE_SWIFT_RPATH" "$APP/Contents/MacOS/$APP_NAME" \
        2>/dev/null && log "  stripped host rpath: $XCODE_SWIFT_RPATH" || true
fi

# --- Sign ------------------------------------------------------------------
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" = "-" ]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--timestamp)
fi

APP_SIGN_ARGS=("${SIGN_ARGS[@]}")
if [ "${HARDENED:-0}" = "1" ]; then
    APP_SIGN_ARGS+=(--options runtime --entitlements "$ROOT/Resources/$APP_NAME.entitlements")
fi

log "signing libraries (identity: $SIGN_IDENTITY)"
# Sign nested code first, then the app.
for lib in "$APP/Contents/Frameworks/"*.dylib; do
    codesign "${SIGN_ARGS[@]}" "$lib"
done
for bundle in "$APP/Contents/Resources/"*.bundle; do
    [ -e "$bundle" ] && codesign "${SIGN_ARGS[@]}" "$bundle"
done

log "signing app"
codesign "${APP_SIGN_ARGS[@]}" "$APP"

log "verifying"
codesign --verify --deep --strict --verbose=2 "$APP" || log "WARNING: codesign verification reported issues"

log "done → $APP"
log "run with: open \"$APP\"   (or pass a file: open -a \"$APP\" connection.vv)"

# --- Package for distribution ----------------------------------------------
# Use ditto (NOT plain zip): it keeps the nested ad-hoc code signatures and
# extended attributes that plain zip mangles. Publish the
# SHA-256 in the release notes — for an unsigned/un-notarized download it is the
# only integrity signal users get.
if [ "${PACKAGE:-1}" = "1" ]; then
    ZIP="$OUT/$APP_NAME.app.zip"
    rm -f "$ZIP" "$ZIP.sha256"
    log "packaging → $ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    ( cd "$OUT" && shasum -a 256 "$APP_NAME.app.zip" | tee "$APP_NAME.app.zip.sha256" )
    log "SHA-256 written → $ZIP.sha256 (publish this in the release notes)"
fi
