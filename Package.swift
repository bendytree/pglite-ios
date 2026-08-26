// swift-tools-version:5.9
import PackageDescription

// The binary target resolves from the GitHub release asset. For local
// development against a modified engine, temporarily swap it for:
//   .binaryTarget(name: "PGliteC", path: "build/PGliteC.xcframework")
// (built via `make xcframework`). native/scripts/release.sh produces the
// release zip and prints the checksum for tagging.
let package = Package(
    name: "PGliteKit",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "PGliteKit", targets: ["PGliteKit"])
    ],
    targets: [
        .binaryTarget(
            name: "PGliteC",
            url: "https://github.com/bendytree/pglite-ios/releases/download/v0.1.0/PGliteC.xcframework.zip",
            checksum: "3e8d4d18f5b1f026c016bd5ec9acf81fb6ffc6170d64a285f380a92969f5935c"
        ),
        .target(
            name: "PGliteKit",
            dependencies: ["PGliteC"],
            resources: [.copy("Resources/pgroot"), .copy("Resources/pgdata-pristine.aar")]
        ),
        .testTarget(
            name: "PGliteKitTests",
            dependencies: ["PGliteKit"]
        ),
    ]
)
