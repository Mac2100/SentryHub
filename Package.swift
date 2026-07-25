// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SentryHub",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SentryHub",
            path: "Sources/SentryHub"
        )
    ]
)
