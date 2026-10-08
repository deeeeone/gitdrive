// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitDriveCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitDriveCore", targets: ["GitDriveCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "GitDriveCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "GitDriveCoreTests",
            dependencies: ["GitDriveCore"]
        ),
    ]
)
