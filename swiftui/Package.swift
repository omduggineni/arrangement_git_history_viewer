// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ArrangementDiffViewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ArrangementDiffViewer", path: "Sources/ArrangementDiffViewer"),
        .testTarget(name: "ArrangementDiffViewerTests", dependencies: ["ArrangementDiffViewer"], path: "Tests/ArrangementDiffViewerTests"),
    ]
)
