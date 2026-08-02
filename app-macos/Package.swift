// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WDashboard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WDashboardApp", targets: ["WDashboardApp"]),
        .library(name: "WDashboardCore", targets: ["WDashboardCore"]),
    ],
    targets: [
        .target(name: "WDashboardCore"),
        .executableTarget(
            name: "WDashboardApp",
            dependencies: ["WDashboardCore"]
        ),
        .testTarget(
            name: "WDashboardCoreTests",
            dependencies: ["WDashboardCore"]
        ),
    ]
)
