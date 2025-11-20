// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "vPlayer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "vPlayer", targets: ["vPlayer"])
    ],
    targets: [
        .executableTarget(
            name: "vPlayer",
            path: ".",
            exclude: [
                ".gitignore"
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
