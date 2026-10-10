// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WindowInvert",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WindowInvert",
            path: "Sources/WindowInvert",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
