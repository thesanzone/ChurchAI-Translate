// swift-tools-version: 5.10
// Builds the Mac version with Apple's Command Line Tools (no Xcode needed):
//   ./build_mac_app.sh
// The iPad version is built from project.yml with Xcode (see README.md).
import PackageDescription

let package = Package(
    name: "ChurchTranslate",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "ChurchTranslate", path: "Sources/ChurchTranslate"),
    ]
)
