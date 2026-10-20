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
        .library(name: "DarkroomCore", targets: ["DarkroomCore"]),
        .executable(name: "darkroom-core-check", targets: ["DarkroomCoreCheck"]),
        .library(name: "DarkroomMetal", targets: ["DarkroomMetal"]),
        .executable(name: "darkroom-metal-check", targets: ["DarkroomMetalCheck"]),
        .executable(name: "Darkroom", targets: ["Darkroom"]),
        .executable(name: "dtb-selftest", targets: ["DarkroomSelfTest"]),
    ],
    targets: [
        // header-only view of src/swiftbridge/dtb.h (plain C types only)
        .systemLibrary(name: "CDtBridge", path: "Sources/CDtBridge"),

        // what every engine speaks: the protocol, shared value types, module schema.
        // No darktable here, so the clean engine can depend on it alone.
        .target(name: "DarkroomEngineAPI"),

        // the engine wrapper
        .target(
            name: "DarktableKit",
            dependencies: ["CDtBridge", "DarkroomEngineAPI"],
            linkerSettings: [
                .unsafeFlags(["-L\(libdir)", "-Xlinker", "-rpath", "-Xlinker", libdir]),
            ]
        ),

        // the clean engine's maths: pure Swift, no darktable, no dylibs (see THIRD-PARTY.md)
        .target(name: "DarkroomCore"),

        // chart checks for DarkroomCore (T-series from the engine roadmap)
        .executableTarget(name: "DarkroomCoreCheck", dependencies: ["DarkroomCore"]),

        // the clean engine's decode and render: Apple's Core Image, behind PhotoEngine
        .target(name: "DarkroomCI", dependencies: ["DarkroomEngineAPI"]),

        // Metal kernels for the clean engine, each checked against the DarkroomCore oracle (L3)
        .target(name: "DarkroomMetal", dependencies: ["DarkroomCore"]),
        .executableTarget(name: "DarkroomMetalCheck", dependencies: ["DarkroomMetal", "DarkroomCore"]),

        // model + SwiftUI views, a library so the self-test can render them offscreen
        .target(
            name: "DarkroomUI",
            dependencies: ["DarktableKit", "DarkroomCI"]
        ),

        // headless check: start the engine, render, time it, write PNGs
        .executableTarget(
            name: "DarkroomSelfTest",
            dependencies: ["DarktableKit", "DarkroomUI", "DarkroomCI"]
        ),

        // the SwiftUI app
        .executableTarget(
            name: "Darkroom",
            dependencies: ["DarkroomUI"]
        ),
    ]
)
