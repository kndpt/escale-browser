// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Escale",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Escale",
            path: "Sources/Escale",
            exclude: ["GitHub/Assets/README.md"],
            resources: [
                .process("Blocking/Scripts"),
                .process("Browser/Scripts"),
                .process("Extensions/Scripts"),
                .copy("GitHub/Assets/github-invertocat.pdf"),
                .process("GitHub/Scripts"),
                .process("Page/Scripts"),
                .process("Passwords/Scripts"),
                .process("Tabs/Scripts"),
            ],
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EscaleTests",
            dependencies: ["Escale"],
            path: "Tests/EscaleTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
