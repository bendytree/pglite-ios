// swift-tools-version:5.9
import PackageDescription

// The binary target points at the locally built xcframework
// (`make xcframework`, output in build/). Release tags swap this for a
// url + checksum binaryTarget pointing at the GitHub release asset — see
// docs in README.md ("Releasing").
let package = Package(
    name: "PGliteKit",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "PGliteKit", targets: ["PGliteKit"])
    ],
    targets: [
        .binaryTarget(name: "PGliteC", path: "build/PGliteC.xcframework"),
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
