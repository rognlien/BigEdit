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
                .product(name: "Sparkle", package: "Sparkle"),
                "BigEditHelperKit"
            ],
            path: "Sources/BigEdit"
        ),
        .target(
            name: "BigEditHelperKit",
            path: "Sources/BigEditHelperKit"
        ),
        // The privileged helper. Its embedded Info.plist and launchd.plist are
        // linked in by make-app.sh's build, which SMJobBless requires; see the
        // linker flags there.
        .executableTarget(
            name: "BigEditHelper",
            dependencies: ["BigEditHelperKit"],
            path: "Sources/BigEditHelper",
            exclude: ["Info.plist", "Launchd.plist"],
            linkerSettings: [
                // SMJobBless will not install a helper unless these are
                // embedded in the binary itself. Paths are relative to the
                // package root, which is where swift build runs.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/BigEditHelper/Info.plist",
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT", "-Xlinker", "__launchd_plist",
                    "-Xlinker", "Sources/BigEditHelper/Launchd.plist"
                ])
            ]
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
            dependencies: ["BigEdit", "BigEditCLI", "BigEditHelperKit"],
            path: "Tests/BigEditTests"
        )
    ]
)
