// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ghbdtn",
    platforms: [
        // 13.3 (not 13.0) because the prebuilt whisper.cpp dylib is built
        // with a 13.3 deployment target.
        .macOS("13.3")
    ],
    targets: [
        .executableTarget(
            name: "Ghbdtn",
            dependencies: ["whisper"],
            path: "Sources/Ghbdtn",
            resources: [
                // Character 4-gram models (see tools/train_ngram.py). Packed
                // into Ghbdtn_Ghbdtn.bundle next to the built binary; build.sh
                // copies that bundle into the .app's Contents/Resources.
                .copy("Resources/Models"),
                // Shared learned words (committed via tools/save-learned.sh) so
                // a fresh install already knows what you taught the app. A
                // `--clean` install strips this from the bundle (build.sh).
                .copy("Resources/seed-learned.json")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                // whisper.framework is a dynamic library with install name
                // @rpath/whisper.framework/... — the app bundle carries it in
                // Contents/Frameworks; bare `swift build` runs (selftest) find
                // it next to the executable (build.sh copies it there too).
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path"
                ])
            ]
        ),
        // Prebuilt whisper.cpp (Metal-accelerated, MIT). Not committed:
        // run tools/fetch-whisper.sh (build.sh does it automatically).
        .binaryTarget(
            name: "whisper",
            path: "Vendor/whisper.xcframework"
        )
    ]
)
