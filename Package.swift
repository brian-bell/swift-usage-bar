// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIUsageBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "UsageCore",
            targets: ["UsageCore"]
        ),
        .executable(
            name: "AIUsageBarApp",
            targets: ["AIUsageBarApp"]
        )
    ],
    targets: [
        .target(
            name: "UsageCore"
        ),
        .executableTarget(
            name: "AIUsageBarApp",
            dependencies: ["UsageCore"]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            // CommandLineTools-only Swift 6.3 exposes Swift Testing from this
            // framework path, but does not provide XCTest.framework.
            swiftSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ])
            ]
        ),
        .testTarget(
            name: "AIUsageBarAppTests",
            dependencies: ["AIUsageBarApp", "UsageCore"],
            // CommandLineTools-only Swift 6.3 exposes Swift Testing from this
            // framework path, but does not provide XCTest.framework.
            swiftSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ])
            ]
        )
    ]
)
