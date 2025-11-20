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
        .binaryTarget(
            name: "VLCKit",
            path: "ThirdParty/VLCKit/VLCKit.xcframework"
        ),
        .executableTarget(
            name: "vPlayer",
            dependencies: [
                "VLCKit"
            ],
            path: ".",
            exclude: [
                ".gitignore",
                "ThirdParty"
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
