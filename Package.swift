// swift-tools-version: 6.2
//
//  Package.swift
//  NiceLyricsX
//
//  Swift Package Manager 清单 —— 提供命令行构建入口,主要工程仍是 Xcode 项目。
//  使用:swift build -c release
//

import PackageDescription

let package = Package(
    name: "NiceLyricsX",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "NiceLyricsX", targets: ["NiceLyricsX"])
    ],
    targets: [
        .executableTarget(
            name: "NiceLyricsX",
            path: "LyricsMenu",
            exclude: [
                "Resources/Info.plist",
                "Resources/NiceLyricsX.entitlements",
                "Resources/Assets.xcassets"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "NiceLyricsXTests",
            dependencies: ["NiceLyricsX"],
            path: "Tests/NiceLyricsXTests"
        )
    ]
)