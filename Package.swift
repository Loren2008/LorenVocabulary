// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IELTS-Vocab",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .executableTarget(
            name: "IELTS-Vocab",
            dependencies: ["CSQLite"],
            path: "Sources",
            exclude: ["CSQLite"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "IELTSVocabTests",
            dependencies: ["IELTS-Vocab"],
            path: "Tests",
            exclude: ["test_expansion_pipeline.py", "__pycache__"]
        )
    ]
)
