// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "KeeMac",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "KeeMacApp",
            targets: ["App"]
        ),
        .executable(
            name: "keemac-proxy",
            targets: ["Proxy"]
        ),
        .library(
            name: "Domain",
            targets: ["Domain"]
        ),
        .library(
            name: "Data",
            targets: ["Data"]
        ),
        .library(
            name: "UI",
            targets: ["UI"]
        )
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "KissXML",
            path: "Vendor/KissXML.xcframework"
        ),
        .binaryTarget(
            name: "KeePassKit",
            path: "Vendor/KeePassKit.xcframework"
        ),
        .target(
            name: "Domain",
            resources: [
                .process("Resources/Localization")
            ]
        ),
        .target(
            name: "CTweetNaCl"
        ),
        .target(
            name: "CBcryptPBKDF"
        ),
        .target(
            name: "UndoSupport"
        ),
        .target(
            name: "BrowserIntegration",
            dependencies: ["Domain", "CTweetNaCl"]
        ),
        .target(
            name: "SSHAgent",
            dependencies: ["CBcryptPBKDF"]
        ),
        .target(
            name: "HardwareKey",
            dependencies: ["Domain"]
        ),
        .executableTarget(
            name: "Proxy"
        ),
        .target(
            name: "Data",
            dependencies: [
                "Domain",
                "KeePassKit",
                "KissXML",
                "UndoSupport"
            ]
        ),
        .target(
            name: "UI",
            dependencies: ["Domain", "Data", "BrowserIntegration", "SSHAgent", "HardwareKey"],
            resources: [
                .copy("Resources/Licenses"),
                .copy("Resources/WordLists"),
                .process("Resources/Localization")
            ]
        ),
        .executableTarget(
            name: "App",
            dependencies: ["Domain", "Data", "UI"],
            path: "Sources/App",
            exclude: [
                "Resources/AppIcon.iconset"
            ],
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "DataTests",
            dependencies: ["Data", "Domain", "UI", "BrowserIntegration", "SSHAgent", "HardwareKey", "Proxy"]
        )
    ],
    swiftLanguageModes: [.v6]
)
