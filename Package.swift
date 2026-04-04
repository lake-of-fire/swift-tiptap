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
    targets: [
        .target(
            name: "TipTapSwift",
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
