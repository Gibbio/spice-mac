// swift-tools-version:5.5

import Foundation
import PackageDescription

// spice-mac fork addition: suppress upstream CocoaSpice's benign ObjC warnings so
// the host app gets a clean build. No source/logic change.
let quietWarnings = [
    "-Wno-objc-duplicate-category-definition",
    "-Wno-objc-designated-initializers",
    "-Wno-incomplete-implementation",
    "-Wno-return-type",
]

// spice-mac fork addition: compile against the headers of the native stack that
// scripts/build-deps.sh installs into <spice-mac>/Sysroot — the same build the app
// links — rather than a vendored copy that can drift from it.
let sysroot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../Sysroot")
    .standardizedFileURL.path
let sysrootHeaders = [
    "include", "include/glib-2.0", "lib/glib-2.0/include",
    "include/libusb-1.0", "include/pixman-1", "include/spice-1", "include/spice-client-glib-2.0",
].flatMap { ["-I", "\(sysroot)/\($0)"] }

let package = Package(
    name: "CocoaSpice",
    platforms: [
        .iOS(.v11), .macOS(.v10_14)
    ],
    products: [
        .library(
            name: "CocoaSpice",
            targets: ["CocoaSpice"]),
        .library(
            name: "CocoaSpiceNoUsb",
            targets: ["CocoaSpiceNoUsb"]),
        // spice-mac fork addition: expose the renderer so a Swift host app can
        // `import CocoaSpiceRenderer` to construct CSMetalRenderer.
        .library(
            name: "CocoaSpiceRenderer",
            targets: ["CocoaSpiceRenderer"]),
    ],
    targets: [
        .target(
            name: "CocoaSpiceRenderer",
            dependencies: [],
            resources: [
                .process("CSShaders.metal")],
            // spice-mac: silence upstream's benign ObjC warnings for a clean build.
            cSettings: [
                .unsafeFlags(quietWarnings)]),
        .target(
            name: "CocoaSpice",
            dependencies: ["CocoaSpiceRenderer"],
            exclude: ["ExternalHeaders"],
            cSettings: [
                .define("WITH_USB_SUPPORT"),
                .unsafeFlags(quietWarnings + sysrootHeaders)]),
        .target(
            name: "CocoaSpiceNoUsb",
            dependencies: ["CocoaSpiceRenderer"],
            exclude: [
                "ExternalHeaders",
                "CSUSBDevice.m",
                "CSUSBManager.m"],
            cSettings: [
                .unsafeFlags(sysrootHeaders)]),
        .testTarget(
            name: "CocoaSpiceTests",
            dependencies: ["CocoaSpice"],
            linkerSettings: [
                .linkedLibrary("glib-2.0"),
                .linkedLibrary("usb-1.0"),
                .linkedLibrary("spice-client-glib-2.0")]),
    ]
)
