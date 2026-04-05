// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mht2webarchive",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "MHTWebArchiveCore",
            targets: ["MHTWebArchiveCore"]
        ),
        .executable(
            name: "mht2webarchive",
            targets: ["mht2webarchive"]
        ),
    ],
    targets: [
        .target(
            name: "MHTWebArchiveImageCompatibility"
        ),
        .target(
            name: "MHTWebArchiveCore",
            dependencies: ["MHTWebArchiveImageCompatibility"]
        ),
        .target(
            name: "MHTWebArchiveCLI",
            dependencies: ["MHTWebArchiveCore"]
        ),
        .executableTarget(
            name: "mht2webarchive",
            dependencies: ["MHTWebArchiveCLI"]
        ),
        .executableTarget(
            name: "mht2webarchiveIntegrationTests",
            dependencies: [
                "MHTWebArchiveCore",
                "MHTWebArchiveCLI",
            ],
            path: "Tests/mht2webarchiveTests",
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
