// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "OpenGlyph",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OpenGlyph", targets: ["OpenGlyph"]), .library(name: "OpenGlyphCore", targets: ["OpenGlyphCore"])],
    targets: [
        .target(name: "OpenGlyphCore"),
        .executableTarget(name: "OpenGlyph", dependencies: ["OpenGlyphCore"]),
        .testTarget(name: "OpenGlyphCoreTests", dependencies: ["OpenGlyphCore"])
    ]
)
