// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Clementine",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clementine",
            path: "Sources/Clementine",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "ClementineTests", dependencies: ["Clementine"], path: "Tests/ClementineTests"),
    ]
)
