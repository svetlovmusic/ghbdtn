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
            resources: [
                // Character 4-gram models (see tools/train_ngram.py). Packed
                // into Ghbdtn_Ghbdtn.bundle next to the built binary; build.sh
                // copies that bundle into the .app's Contents/Resources.
                .copy("Resources/Models")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation")
            ]
        )
    ]
)
