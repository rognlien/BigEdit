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
        .target(
            name: "BigEditCLI",
            path: "Sources/BigEditCLI"
        ),
        // Named BigEditTool rather than bigedit: the filesystem is
        // case-insensitive, so a target called "bigedit" collides with
        // "BigEdit" in .build. make-app.sh installs the built binary into the
        // bundle under its real name, `bigedit`.
        .executableTarget(
            name: "BigEditTool",
            dependencies: ["BigEditCLI"],
            path: "Sources/BigEditTool"
        ),
        .testTarget(
            name: "BigEditTests",
            dependencies: ["BigEdit", "BigEditCLI"],
            path: "Tests/BigEditTests"
        )
    ]
)
