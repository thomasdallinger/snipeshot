// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Snipeshot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Snipeshot",
            path: "Sources/Snipeshot",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
