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
        .executableTarget(
            name: "BunnyUploader",
            dependencies: [
                .product(name: "TUSKit", package: "TUSKit"),
            ],
            path: "Sources/BunnyUploader"
        ),
    ]
)
