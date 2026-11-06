// swift-tools-version: 5.10
// Builds the Mac version with Apple's Command Line Tools (no Xcode needed):
//   ./fetch_piper.sh      (once: downloads the Piper voice engine + voice)
//   ./build_mac_app.sh
// The iPad version is built from project.yml with Xcode (see README.md).
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorLib = root + "/Vendor/lib"
// Piper is linked only when ./fetch_piper.sh has been run; otherwise Apple voices are used.
let hasPiper = FileManager.default.fileExists(atPath: vendorLib + "/libsherpa-onnx-c-api.a")
    && FileManager.default.fileExists(atPath: root + "/Vendor/CSherpaOnnx/include/c-api.h")

// Order matters for static linking: users before the libraries they depend on.
let piperLibs = [
    "sherpa-onnx-c-api", "sherpa-onnx-core", "sherpa-onnx-cxx-api", "kaldi-decoder-core",
    "sherpa-onnx-kaldifst-core", "sherpa-onnx-fstfar", "sherpa-onnx-fst", "kaldi-native-fbank-core",
    "piper_phonemize", "espeak-ng", "ucd", "kissfft-float", "ssentencepiece_core", "onnxruntime",
]

var appDeps: [Target.Dependency] = []
var appLinker: [LinkerSetting] = []
var targets: [Target] = []

if hasPiper {
    targets.append(.target(name: "CSherpaOnnx", path: "Vendor/CSherpaOnnx"))
    appDeps.append("CSherpaOnnx")
    appLinker = [.unsafeFlags(["-L", vendorLib])]
        + piperLibs.map { .linkedLibrary($0) }
        + [.linkedLibrary("c++"), .linkedFramework("CoreML"), .linkedFramework("Foundation")]
}

targets.append(
    .executableTarget(
        name: "ChurchTranslate",
        dependencies: appDeps,
        path: "Sources/ChurchTranslate",
        linkerSettings: appLinker
    )
)

let package = Package(
    name: "ChurchTranslate",
    platforms: [.macOS("26.0")],
    targets: targets
)
