// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ghbdtn",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Ghbdtn",
            path: "Sources/Ghbdtn",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
