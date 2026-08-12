// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShotX",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ShotX", targets: ["ShotX"])],
    targets: [
        .executableTarget(
            name: "ShotX",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ShotXTests", dependencies: ["ShotX"])
    ]
)
