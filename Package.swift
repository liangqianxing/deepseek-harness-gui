// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeepSeekHarnessGUI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DeepSeekHarnessGUI", targets: ["DeepSeekHarnessGUI"])
    ],
    targets: [
        .executableTarget(
            name: "DeepSeekHarnessGUI",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("WebKit")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
