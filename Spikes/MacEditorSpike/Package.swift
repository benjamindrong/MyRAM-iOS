// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MyRAMMacEditorSpike",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MacEditorCore",
            targets: ["MacEditorCore"]
        ),
        .executable(
            name: "MyRAMMacEditorSpike",
            targets: ["MyRAMMacEditorSpike"]
        )
    ],
    targets: [
        .target(
            name: "MacEditorCore"
        ),
        .executableTarget(
            name: "MyRAMMacEditorSpike",
            dependencies: ["MacEditorCore"]
        ),
        .testTarget(
            name: "MacEditorCoreTests",
            dependencies: ["MacEditorCore"]
        )
    ]
)
