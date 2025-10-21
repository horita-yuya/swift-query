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
            name: "SwiftQuery",
            targets: ["SwiftQuery"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftQuery"
        ),
        .testTarget(
            name: "SwiftQueryTests",
            dependencies: ["SwiftQuery"]
        ),
    ]
)
