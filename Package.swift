// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-query",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "swift-query",
            targets: ["swift-query"]
        ),
    ],
    targets: [
        .target(
            name: "swift-query"
        ),
        .testTarget(
            name: "swift-queryTests",
            dependencies: ["swift-query"]
        ),
    ]
)
