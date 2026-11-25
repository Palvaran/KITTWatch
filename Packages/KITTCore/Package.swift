// swift-tools-version:5.9
import PackageDescription

// KITTCore holds everything that must behave identically on the watch and the Mac:
// unit-typed calculators, the reviewed guide pack, the append-only conversation log,
// household facts, routing, and prompt building. It has no UI and no llama.cpp
// dependency, so it builds and tests on macOS, Linux, and watchOS alike.
let package = Package(
    name: "KITTCore",
    platforms: [
        .watchOS(.v10),
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "KITTCore", targets: ["KITTCore"]),
    ],
    targets: [
        .target(
            name: "KITTCore",
            resources: [.copy("Resources/guide-pack.json")]
        ),
        .testTarget(
            name: "KITTCoreTests",
            dependencies: ["KITTCore"]
        ),
    ]
)
