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
            name: "MHTWebArchiveCore"
        ),
        .executableTarget(
            name: "mht2webarchive",
            dependencies: ["MHTWebArchiveCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
