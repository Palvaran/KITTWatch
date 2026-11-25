// swift-tools-version:5.9
import Foundation
import PackageDescription

// KITTEngine wraps llama.cpp behind KITTCore's TextGenerating protocol and ships the
// `kitt` command-line tool (ask / eval / bench). The same engine source runs on the
// watch, on the Mac, and on Linux, so behaviour can be measured off the wrist.
//
// Where the `llama` C module comes from:
//   - default: Frameworks/llama.xcframework, built by scripts/build-llama.sh
//     (watchOS device + simulator slices). This is what Xcode uses for the watch app.
//   - KITT_LLAMA_PREFIX=/path: a host build made by scripts/build-llama-host.sh
//     (include/ + lib/libllama-kitt.a). Used for `swift test` and `swift run kitt`
//     on macOS and Linux. scripts/kitt sets it for you.
let hostPrefix = ProcessInfo.processInfo.environment["KITT_LLAMA_PREFIX"].flatMap { $0.isEmpty ? nil : $0 }

var targets: [Target] = []
var engineDependencies: [Target.Dependency] = [.product(name: "KITTCore", package: "KITTCore")]
var swiftSettings: [SwiftSetting] = []
var linkerSettings: [LinkerSetting] = []

if let hostPrefix {
    swiftSettings = [.unsafeFlags([
        "-Xcc", "-I\(hostPrefix)/include",
        "-Xcc", "-fmodule-map-file=\(hostPrefix)/include/module.modulemap",
    ])]
    linkerSettings = [
        .unsafeFlags(["-L\(hostPrefix)/lib"]),
        .linkedLibrary("llama-kitt"),
        .linkedLibrary("c++", .when(platforms: [.macOS])),
        .linkedLibrary("stdc++", .when(platforms: [.linux])),
        .linkedLibrary("m", .when(platforms: [.linux])),
    ]
} else {
    targets.append(.binaryTarget(name: "llama", path: "Frameworks/llama.xcframework"))
    engineDependencies.append("llama")
}

targets += [
    .target(
        name: "KITTEngine",
        dependencies: engineDependencies,
        swiftSettings: swiftSettings,
        linkerSettings: linkerSettings
    ),
    .executableTarget(
        name: "kitt",
        dependencies: ["KITTEngine", .product(name: "KITTCore", package: "KITTCore")],
        swiftSettings: swiftSettings
    ),
    .testTarget(
        name: "KITTEngineTests",
        dependencies: ["KITTEngine", .product(name: "KITTCore", package: "KITTCore")],
        swiftSettings: swiftSettings
    ),
]

let package = Package(
    name: "KITTEngine",
    platforms: [.watchOS(.v10), .macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KITTEngine", targets: ["KITTEngine"]),
        .executable(name: "kitt", targets: ["kitt"]),
    ],
    dependencies: [.package(path: "../KITTCore")],
    targets: targets
)
