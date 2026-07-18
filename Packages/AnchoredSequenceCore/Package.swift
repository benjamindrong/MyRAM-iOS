// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnchoredSequenceCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .macCatalyst(.v17)
    ],
    products: [
        .library(
            name: "AnchoredSequenceCore",
            targets: ["AnchoredSequenceCore"]
        )
    ],
    targets: [
        .target(
            name: "AnchoredSequenceCore"
        ),
        .testTarget(
            name: "AnchoredSequenceCoreTests",
            dependencies: ["AnchoredSequenceCore"]
        )
    ]
)
