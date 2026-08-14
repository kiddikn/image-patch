// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImagePatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ImagePatch",
            path: "Sources/ImagePatch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
