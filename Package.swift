// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cp",
    platforms: [
        // Observation (`@Observable`), `onKeyPress`, and `SettingsLink` all land here.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "cp", targets: ["cp"])
    ],
    targets: [
        // Thin shell: scenes and the app delegate, nothing testable.
        .executableTarget(
            name: "cp",
            dependencies: ["CpKit"],
            path: "Sources/cp"
        ),
        // Everything else, so the model, search and transform logic can be tested
        // without standing up an app.
        .target(
            name: "CpKit",
            path: "Sources/CpKit"
        ),
        .testTarget(
            name: "CpKitTests",
            dependencies: ["CpKit"],
            path: "Tests/CpKitTests"
        ),
    ]
)
