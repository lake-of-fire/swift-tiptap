// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-tiptap",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TipTapSwift",
            targets: ["TipTapSwift"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/johnpatrickmorgan/NavigationBackport.git", branch: "main")
    ],
    targets: [
        .target(
            name: "TipTapSwift",
            dependencies: [
                .product(name: "NavigationBackport", package: "NavigationBackport")
            ],
            resources: [
                .copy("Resources/RichTextEditor")
            ]
        ),
        .testTarget(
            name: "TipTapSwiftTests",
            dependencies: ["TipTapSwift"]
        )
    ]
)
