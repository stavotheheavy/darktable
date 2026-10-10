// swift-tools-version: 6.2
import PackageDescription

// Where the fork was installed (`./build.sh --install --prefix ...`). The engine
// and its dylibs are found here at link and run time. Override per machine by
// editing this one line; packaging the dylibs into an .app is a later job.
let prefix = "/Users/Chief/darktable/build/install"
let libdir = "\(prefix)/lib/darktable"

let package = Package(
    name: "Darkroom",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DarktableKit", targets: ["DarktableKit"]),
        .library(name: "DarkroomUI", targets: ["DarkroomUI"]),
        .executable(name: "Darkroom", targets: ["Darkroom"]),
        .executable(name: "dtb-selftest", targets: ["DarkroomSelfTest"]),
    ],
    targets: [
        // header-only view of src/swiftbridge/dtb.h (plain C types only)
        .systemLibrary(name: "CDtBridge", path: "Sources/CDtBridge"),

        // the engine wrapper
        .target(
            name: "DarktableKit",
            dependencies: ["CDtBridge"],
            linkerSettings: [
                .unsafeFlags(["-L\(libdir)", "-Xlinker", "-rpath", "-Xlinker", libdir]),
            ]
        ),

        // model + SwiftUI views, a library so the self-test can render them offscreen
        .target(
            name: "DarkroomUI",
            dependencies: ["DarktableKit"]
        ),

        // headless check: start the engine, render, time it, write PNGs
        .executableTarget(
            name: "DarkroomSelfTest",
            dependencies: ["DarktableKit", "DarkroomUI"]
        ),

        // the SwiftUI app
        .executableTarget(
            name: "Darkroom",
            dependencies: ["DarkroomUI"]
        ),
    ]
)
