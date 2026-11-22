// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OllamaTranslator",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OllamaTranslator", targets: ["OllamaTranslator"])
    ],
    targets: [
        .executableTarget(
            name: "OllamaTranslator",
            path: "Sources/OllamaTranslator",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
