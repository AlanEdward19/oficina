// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Oficina",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Oficina",
            path: "Sources/Oficina",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ]
)
