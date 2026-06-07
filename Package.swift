// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BigEdit",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "BigEdit",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/BigEdit"
        ),
        .testTarget(
            name: "BigEditTests",
            dependencies: ["BigEdit"],
            path: "Tests/BigEditTests"
        )
    ]
)
