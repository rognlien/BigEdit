// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BigEdit",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "BigEdit",
            path: "Sources/BigEdit"
        ),
        .testTarget(
            name: "BigEditTests",
            dependencies: ["BigEdit"],
            path: "Tests/BigEditTests"
        )
    ]
)
