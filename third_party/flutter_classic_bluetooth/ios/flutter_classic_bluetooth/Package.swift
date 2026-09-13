// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "flutter_classic_bluetooth",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "flutter-classic-bluetooth", targets: ["flutter_classic_bluetooth"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "flutter_classic_bluetooth",
            dependencies: [],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedFramework("ExternalAccessory"),
            ]
        )
    ]
)
