// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "utter",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "utter"),
    ]
)
