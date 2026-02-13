// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "KeeMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "KeeMacApp",
            targets: ["App"]
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
            name: "Domain"
        ),
        .target(
            name: "Data",
            dependencies: [
                "Domain",
                "KeePassKit",
                "KissXML"
            ]
        ),
        .target(
            name: "UI",
            dependencies: ["Domain", "Data"]
        ),
        .executableTarget(
            name: "App",
            dependencies: ["Domain", "Data", "UI"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "DataTests",
            dependencies: ["Data", "Domain"]
        )
    ],
    swiftLanguageModes: [.v6]
)
