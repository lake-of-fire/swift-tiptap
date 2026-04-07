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
        .package(
            url: "https://github.com/johnpatrickmorgan/NavigationBackport.git",
            revision: "540d823fdfbbe495cbbe0afc80c409d63c9995c0"
        )
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
