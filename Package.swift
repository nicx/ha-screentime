// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HAScreenTime",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HAScreenTime",
            path: "Sources/HAScreenTime"
        )
    ],
    swiftLanguageModes: [.v5]
)
