// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalendarSync",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CalendarSync", targets: ["CalendarSync"])],
    targets: [
        .executableTarget(name: "CalendarSync", path: "Sources/CalendarSync"),
        .testTarget(name: "CalendarSyncTests", dependencies: ["CalendarSync"], path: "Tests/CalendarSyncTests")
    ]
)
