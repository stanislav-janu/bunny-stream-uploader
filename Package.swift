// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BunnyUploader",
    platforms: [
        .macOS("26.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/tus/TUSKit.git", from: "3.2.0"),
    ],
    targets: [
        .target(
            name: "BunnyUploaderCore",
            dependencies: [
                .product(name: "TUSKit", package: "TUSKit"),
            ],
            path: "Sources/BunnyUploaderCore"
        ),
        .executableTarget(
            name: "BunnyUploader",
            dependencies: [
                "BunnyUploaderCore",
            ],
            path: "Sources/BunnyUploader"
        ),
        .testTarget(
            name: "BunnyUploaderCoreTests",
            dependencies: [
                "BunnyUploaderCore",
            ],
            path: "Tests/BunnyUploaderCoreTests"
        ),
    ]
)
