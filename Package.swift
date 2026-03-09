// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "n42-dump-xcode-buildsettings",
    products: [
        .executable(
            name: "n42-dump-xcode-buildsettings",
            targets: ["n42-dump-xcode-buildsettings"]
        )
    ],
    targets: [
        .executableTarget(
            name: "n42-dump-xcode-buildsettings"
        ),
        .testTarget(
            name: "n42-dump-xcode-buildsettingsTests",
            dependencies: ["n42-dump-xcode-buildsettings"]
        ),
    ]
)
