#!/usr/bin/env bash
#
# build-deps.sh — build the native SPICE client stack (arm64, macOS 12+) from the
# pinned sources in deps/sources.lock into ./Sysroot, which Package.swift links and
# build-app.sh embeds.
#
#   ./scripts/build-deps.sh              build everything not yet built
#   ./scripts/build-deps.sh glib pixman  (re)build just these packages
#   ./scripts/build-deps.sh --clean      wipe .deps/ and Sysroot/ first
#
# Output (./Sysroot):
#   lib/*.dylib               runtime libraries, install names rewritten to @rpath
#   include/, lib/*/include   headers CocoaSpice compiles against
#
# The build is hermetic on purpose: Homebrew's pkg-config/meson/cmake/ninja are used
# as TOOLS, but nothing may be found or linked from /opt/homebrew. Every download is
# SHA-256 checked and the build fails closed on a mismatch; meson may not fetch
# subprojects on its own (--wrap-mode=nodownload). The final check rejects any
# library that references a path outside @rpath or the OS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/deps/sources.lock"
PATCHES="$ROOT/deps/patches"
WORK="${SPICEMAC_DEPS_WORK:-$ROOT/.deps}"
PREFIX="$ROOT/Sysroot"
DL="$WORK/downloads"
SRC="$WORK/src"
BLD="$WORK/build"
STAMPS="$WORK/stamps"
LOGS="$WORK/logs"
JOBS="$(sysctl -n hw.ncpu)"
MIN_MACOS=12.0

log() { printf '\033[1;34m[build-deps]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[build-deps] error:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Environment -------------------------------------------------------------
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon only."
xcode-select -p 2>/dev/null | grep -q "Xcode.app" || die "full Xcode is not selected (run scripts/doctor.sh)."

# --clean must run before anything below creates files under $WORK.
if [ "${1:-}" = "--clean" ]; then
    shift; log "removing $WORK and $PREFIX"; rm -rf "$WORK" "$PREFIX"
fi

# Resolve the build tools once, then expose ONLY them (via a private bin dir) so
# configure scripts cannot stumble on other Homebrew binaries or libraries.
for tool in meson ninja cmake pkg-config python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found (brew install $tool)"
done
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for tool in meson ninja cmake pkg-config; do ln -sf "$(command -v $tool)" "$TOOLS/$tool"; done
HOST_PYTHON="$(command -v python3)"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CC="$(xcrun -f clang)"; CXX="$(xcrun -f clang++)"; OBJC="$CC"
export CC CXX OBJC
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
ARCH_FLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS -isysroot $SDK"
export CFLAGS="$ARCH_FLAGS -O2 -g"
export CXXFLAGS="$CFLAGS"
export OBJCFLAGS="$CFLAGS"
export CPPFLAGS="-I$PREFIX/include"
# headerpad: leaves room for the @rpath rewrite in fix_install_names.
export LDFLAGS="$ARCH_FLAGS -L$PREFIX/lib -Wl,-headerpad_max_install_names"
export PKG_CONFIG="$TOOLS/pkg-config"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
unset PKG_CONFIG_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH \
      CMAKE_PREFIX_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
export PATH="$PREFIX/bin:$WORK/venv/bin:$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"
# Release tarballs version themselves with git-version-gen; keep git from finding the
# enclosing spice-mac checkout (it would stamp e.g. "0.43-dirty" from OUR worktree).
export GIT_CEILING_DIRECTORIES="$WORK"

# --- Sources -----------------------------------------------------------------
lock_field() {  # lock_field <name> <column: 2=version 3=url 4=sha256>
    awk -v n="$1" -v c="$2" '!/^#/ && $1 == n { print $c; found=1 } END { exit !found }' "$LOCK" \
        || die "$1 is not in deps/sources.lock"
}

fetch() {  # fetch <name> → path of the verified archive
    local url sha file got
    url="$(lock_field "$1" 3)"; sha="$(lock_field "$1" 4)"
    file="$DL/$1-$(lock_field "$1" 2)-${url##*/}"
    mkdir -p "$DL"
    if [ ! -f "$file" ] || ! echo "$sha  $file" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$file.part" "$url" || die "download failed: $url"
        if ! echo "$sha  $file.part" | shasum -a 256 -c - >/dev/null 2>&1; then
            got="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
            rm -f "$file.part"
            die "checksum mismatch for $1 ($url): got $got — if you just changed its version, verify that hash and put it in deps/sources.lock"
        fi
        mv "$file.part" "$file"
    fi
    printf '%s\n' "$file"
}

fetch_git() {  # fetch_git <name> <dir> — the pinned commit (with submodules) as a plain tree
    local url commit cache
    url="$(lock_field "$1" 3)"; url="${url#git+}"
    commit="$(lock_field "$1" 4)"
    cache="$DL/$1.git"
    mkdir -p "$DL"
    [ -d "$cache" ] || git clone --quiet --no-checkout "$url" "$cache" || die "clone failed: $url"
    git -C "$cache" cat-file -e "$commit^{commit}" 2>/dev/null \
        || git -C "$cache" fetch --quiet --tags origin || die "fetch failed: $url"
    cp -R "$cache" "$2"
    git -C "$2" -c advice.detachedHead=false checkout --quiet "$commit" || die "no commit $commit in $url"
    [ "$(git -C "$2" rev-parse HEAD)" = "$commit" ] || die "$1 is not at the pinned commit"
    git -C "$2" submodule update --init --recursive --quiet || die "submodules failed for $1"
    # From here on it is just a source tree, like a release tarball: no .git for
    # version scripts to read (they would stamp "-dirty" once patched), and the
    # version comes from .tarball-version like it does for a release, derived from
    # the nearest tag: v0.43-22-g5f26179 → 0.43.22-5f26179.
    git -C "$2" describe --tags --long "$commit" 2>/dev/null \
        | sed -E -e 's/^v//' -e "s/^$1-//" -e 's/-0-g[0-9a-f]+$//' \
                 -e 's/-([0-9]+)-g([0-9a-f]+)$/.\1-\2/' > "$2/.tarball-version"
    find "$2" -name .git -prune -exec rm -rf {} +
}

unpack() {  # unpack <name> → fresh, patched source dir
    # Callers run this as $(unpack …), where bash 3.2 does not apply set -e: every
    # step has to fail explicitly, or a failed download would build an empty tree.
    local url dir archive
    url="$(lock_field "$1" 3)" || exit 1
    dir="$SRC/$1"
    rm -rf "$dir"; mkdir -p "$SRC"
    case "$url" in
        git+*) fetch_git "$1" "$dir" || exit 1 ;;
        *) archive="$(fetch "$1")" || exit 1
           mkdir -p "$dir"
           tar -xf "$archive" -C "$dir" --strip-components 1 || die "cannot unpack $archive" ;;
    esac
    if [ -d "$PATCHES/$1" ]; then
        for p in "$PATCHES/$1"/*.patch; do
            patch -d "$dir" -p1 -s --no-backup-if-mismatch < "$p" || die "patch failed: $p"
        done
    fi
    printf '%s\n' "$dir"
}

# --- Build-system helpers ------------------------------------------------------
meson_pkg() {  # meson_pkg <name> [meson -D options...]
    local name="$1"; shift
    local src; src="$(unpack "$name")"
    [ -z "${PRE_SETUP:-}" ] || "$PRE_SETUP" "$src"   # optional hook on the patched source
    rm -rf "${BLD:?}/${name:?}"
    meson setup "$BLD/$name" "$src" \
        --prefix="$PREFIX" --libdir=lib --buildtype=debugoptimized \
        --wrap-mode=nodownload -Ddefault_library=shared "$@"
    meson compile -C "$BLD/$name" -j "$JOBS"
    meson install -C "$BLD/$name" --no-rebuild
}

cmake_pkg() {  # cmake_pkg <name> [cmake -D options...]
    local name="$1"; shift
    local src; src="$(unpack "$name")"
    rm -rf "${BLD:?}/${name:?}"
    cmake -S "$src" -B "$BLD/$name" -G Ninja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_OSX_SYSROOT="$SDK" "$@"
    cmake --build "$BLD/$name" -j "$JOBS"
    cmake --install "$BLD/$name"
}

configure_pkg() {  # configure_pkg <name> [configure options...] (autotools release tarball)
    local name="$1"; shift
    local src; src="$(unpack "$name")"
    ( cd "$src" && ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" "$@" \
        && make -j "$JOBS" && make install )
}

seed_glib_wraps() {  # seed_glib_wraps <glib source dir>
    mkdir -p "$1/subprojects/packagecache"
    cp "$(fetch proxy-libintl)" "$1/subprojects/packagecache/proxy-libintl-$(lock_field proxy-libintl 2).tar.gz"
}

# --- Packages (build order matters) ------------------------------------------
build_pyparsing() {
    # spice-common generates the protocol (de)marshallers with a python script.
    rm -rf "$WORK/venv"
    "$HOST_PYTHON" -m venv "$WORK/venv"
    local wheel named
    wheel="$(fetch pyparsing)"
    named="$DL/pyparsing-$(lock_field pyparsing 2)-py3-none-any.whl"   # pip needs the canonical name
    cp "$wheel" "$named"
    "$WORK/venv/bin/pip" install --quiet --no-index --no-deps "$named"
}

# A no-op gettext stand-in: glib always needs a libintl, and this app ships no
# translations. Static, so it is folded into the libraries that use it.
build_proxy-libintl() { meson_pkg proxy-libintl -Ddefault_library=static; }

build_libffi() {
    configure_pkg libffi --disable-shared --enable-static --with-pic --disable-docs \
        --disable-multi-os-directory
}

build_pcre2() {
    # Static into libglib (GRegex). No JIT: the hardened runtime denies the
    # writable+executable mappings it needs.
    cmake_pkg pcre2 -DBUILD_SHARED_LIBS=OFF -DPCRE2_BUILD_PCRE2_8=ON \
        -DPCRE2_BUILD_PCRE2_16=OFF -DPCRE2_BUILD_PCRE2_32=OFF -DPCRE2_SUPPORT_JIT=OFF \
        -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF -DPCRE2_SUPPORT_LIBBZ2=OFF \
        -DPCRE2_SUPPORT_LIBZ=OFF -DPCRE2_SUPPORT_LIBEDIT=OFF -DPCRE2_SUPPORT_LIBREADLINE=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
}

build_glib() {
    # glib finds the proxy-libintl installed above; should that probe ever fail it
    # falls back to its own proxy-libintl subproject, so seed the wrap's package
    # cache with the same verified tarball (meson may not download it).
    PRE_SETUP=seed_glib_wraps meson_pkg glib -Dtests=false -Dintrospection=disabled -Ddtrace=disabled \
        -Dsystemtap=disabled -Dsysprof=disabled -Dman-pages=disabled -Ddocumentation=false \
        -Dnls=disabled -Dlibmount=disabled -Dselinux=disabled -Dglib_debug=disabled
}

build_openssl() {
    local src; src="$(unpack openssl)"
    ( cd "$src" && ./Configure darwin64-arm64-cc shared no-tests no-docs no-apps no-module \
        --prefix="$PREFIX" --libdir=lib --openssldir="$PREFIX/ssl" \
        "-mmacosx-version-min=$MIN_MACOS" \
        && make -j "$JOBS" build_libs && make install_dev )
}

build_pixman() {
    meson_pkg pixman -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled \
        -Dopenmp=disabled
}

build_libjpeg-turbo() {
    cmake_pkg libjpeg-turbo -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF \
        -DREQUIRE_SIMD=ON
}

build_opus() { meson_pkg opus -Dtests=disabled -Ddocs=disabled -Dextra-programs=disabled; }

build_json-glib() {
    meson_pkg json-glib -Dintrospection=disabled -Dtests=false -Ddocumentation=disabled \
        -Dman=false -Dnls=disabled
}

build_spice-protocol() { meson_pkg spice-protocol; }

build_libusb() { configure_pkg libusb --disable-static --enable-shared --disable-examples-build; }

build_usbredir() { meson_pkg usbredir -Dtools=disabled -Dfuzzing=disabled -Dtests=disabled; }

build_libucontext() {
    # Fast user-space coroutine switches for spice-gtk's channels (the alternative,
    # gthread coroutines, costs a thread handoff per yield). Only the prefixed
    # libucontext_* API: unprefixed getcontext() & co. would shadow the system's
    # (and Darwin has no symbol aliases for them anyway).
    meson_pkg libucontext -Ddefault_library=static -Dfreestanding=true \
        -Dexport_unprefixed=false -Dbuild_posix=false -Ddocs=false
}

check_spice_main_context() {  # check_spice_main_context <spice-gtk source dir>
    # CocoaSpice runs spice-gtk on its own GMainContext, and the GMainContext patches
    # route spice-gtk's sources there via g_spice_*(). A plain g_idle_add/
    # g_timeout_add lands on the default context, which nothing iterates: the
    # callback silently never runs (a stalled connect, a lost USB hotplug). Upstream
    # can add one in any commit and a rebase will not notice, so check every build.
    local hits
    hits="$(grep -n -E '(^|[^_[:alnum:]])g_(idle|timeout)_add(_full|_seconds)?[[:space:]]*\(' "$1"/src/*.c \
            | grep -v '/spice-util\.c:' \
            | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*(\*|//)' \
            | grep -v -F 'g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, (GSourceFunc) func, spice_migrate_ref(mig)' \
            || true)"
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" >&2
        die "spice-gtk schedules on the default GMainContext above — make it g_spice_*() in deps/patches/spice-gtk (see deps/README.md)"
    fi
}

build_spice-gtk() {
    PRE_SETUP=check_spice_main_context meson_pkg spice-gtk -Dgtk=disabled -Dwebdav=disabled -Dusbredir=enabled \
        -Dsmartcard=disabled -Dsasl=disabled -Dlz4=disabled -Dopus=enabled \
        -Dintrospection=disabled -Dvapi=disabled -Dgtk_doc=disabled -Dpolkit=disabled \
        -Dlibcap-ng=disabled -Dwayland-protocols=disabled -Degl=disabled \
        -Dcoroutine=libucontext -Dbuiltin-mjpeg=true -Dgstreamer=disabled
}

PACKAGES=(pyparsing proxy-libintl libffi pcre2 glib openssl pixman libjpeg-turbo opus
          json-glib spice-protocol libusb usbredir libucontext spice-gtk)

# --- Post-processing ---------------------------------------------------------
fix_install_names() {
    # Every dylib gets an @rpath id and @rpath references to its siblings, so the
    # bundle can live anywhere; @loader_path lets siblings find each other too.
    local lib dep base
    for lib in "$PREFIX"/lib/*.dylib; do
        [ -L "$lib" ] && continue
        base="$(otool -D "$lib" | sed -n 2p)"; base="${base##*/}"
        install_name_tool -id "@rpath/$base" "$lib" 2>/dev/null
        otool -L "$lib" | awk 'NR > 1 { print $1 }' | while read -r dep; do
            case "$dep" in
                "$PREFIX"/lib/*|"$BLD"/*) install_name_tool -change "$dep" "@rpath/${dep##*/}" "$lib" 2>/dev/null ;;
            esac
        done
        otool -l "$lib" | awk '/LC_RPATH/ { f = 1 } f && / path / { print $2; f = 0 }' | while read -r rp; do
            [ "$rp" = "@loader_path" ] || install_name_tool -delete_rpath "$rp" "$lib" 2>/dev/null || true
        done
        otool -l "$lib" | grep -q "path @loader_path " || install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null
        codesign --force --sign - "$lib" 2>/dev/null   # install_name_tool invalidates the signature
    done
}

prune() {
    rm -f "$PREFIX"/lib/*.la
}

verify() {
    local bad=0 lib dep minos
    for lib in "$PREFIX"/lib/*.dylib; do
        [ -L "$lib" ] && continue
        while read -r dep; do
            case "$dep" in
                @rpath/*|/usr/lib/*|/System/*) ;;
                *) printf '  %s → %s\n' "${lib##*/}" "$dep" >&2; bad=1 ;;
            esac
        done < <(otool -L "$lib" | awk 'NR > 1 { print $1 }')
        minos="$(vtool -show-build "$lib" 2>/dev/null | awk '/minos/ { print $2; exit }')"
        if [ "$minos" != "$MIN_MACOS" ]; then
            printf '  %s: minos %s (want %s)\n' "${lib##*/}" "${minos:-?}" "$MIN_MACOS" >&2; bad=1
        fi
    done
    if grep -rlI "/opt/homebrew" "$PREFIX/lib/pkgconfig" >/dev/null 2>&1; then
        printf '  pkg-config files reference /opt/homebrew\n' >&2; bad=1
    fi
    [ "$bad" -eq 0 ] || die "Sysroot verification failed (see above)."
    log "verified: $(ls "$PREFIX"/lib/*.dylib | wc -l | tr -d ' ') dylib entries; @rpath-only, minos $MIN_MACOS"
}

# --- Main --------------------------------------------------------------------
run_logged() {  # run_logged <log name> <function> — fail with the log tail on error
    # Not `if ! fn`: bash ignores `set -e` inside anything run as a condition,
    # which would let a failed step fall through to the next one.
    local rc
    set +e
    ( set -e; "$2" ) >"$LOGS/$1.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        tail -25 "$LOGS/$1.log" >&2
        die "$1 failed — full log: $LOGS/$1.log"
    fi
}

build_stamp() {  # build_stamp <name> — changes whenever what would be built changes:
    # its sources.lock line, its patches, or its build_<name>() options
    { awk -v n="$1" '!/^#/ && $1 == n' "$LOCK"
      cat "$PATCHES/$1"/*.patch 2>/dev/null || true
      declare -f "build_$1"; } | shasum -a 256 | cut -c1-64
}

main() {
    mkdir -p "$PREFIX" "$SRC" "$BLD" "$STAMPS" "$LOGS"

    local requested=("$@") pkg
    [ ${#requested[@]} -gt 0 ] || requested=("${PACKAGES[@]}")
    for pkg in "${requested[@]}"; do
        declare -F "build_$pkg" >/dev/null || die "unknown package: $pkg"
        if [ $# -eq 0 ] && [ -f "$STAMPS/$pkg" ] \
           && [ "$(cat "$STAMPS/$pkg")" = "$(build_stamp "$pkg")" ]; then
            continue
        fi
        log "building $pkg $(lock_field "$pkg" 2)  (log: .deps/logs/$pkg.log)"
        run_logged "$pkg" "build_$pkg"
        build_stamp "$pkg" > "$STAMPS/$pkg"
    done

    prune
    run_logged fixup fix_install_names
    verify
    log "done → $PREFIX"
}

main "$@"
