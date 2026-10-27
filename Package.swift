// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "UnCarambaSwitcher",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "UnCarambaSwitcher",
            path: ".",
            exclude: ["assets", "build", "data", "model", "tools", "README.md", "build.sh"],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
