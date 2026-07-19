// swift-tools-version: 5.9
import Foundation
import PackageDescription

// >>> backend toggle — managed by scripts/set_backend_macos.sh; the script
// rewrites this literal so SwiftPM's manifest cache can never serve a stale
// backend (env-var switches don't bust it).
let useDawnBackend = false
// <<< backend toggle

let pkgDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

var cppSettings: [CXXSetting] = [
    .headerSearchPath("include"),
    .unsafeFlags(["-std=c++17"]),
]
var cppLinkerSettings: [LinkerSetting] = [
    .linkedFramework("Metal"),
    .linkedFramework("QuartzCore"),
]
if useDawnBackend {
    cppSettings.append(.define("NITRO_WEBGPU_BACKEND_DAWN"))
    cppSettings.append(.define("NITRO_WEBGPU_HAS_GLSLANG"))
    cppSettings.append(
        .unsafeFlags(["-I", pkgDir + "/../../src/third_party/dawn/include"]))
    // glslang (brew) provides the GLSL→SPIR-V front end Dawn lacks.
    cppSettings.append(.unsafeFlags(["-I", "/opt/homebrew/include"]))
    cppLinkerSettings.append(.unsafeFlags([
        "-L/opt/homebrew/lib", "-lglslang", "-lglslang-default-resource-limits",
    ]))
}

let package = Package(
    name: "nitro_webgpu",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "nitro-webgpu", targets: ["nitro_webgpu"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        // Backend binary: wgpu-native prebuilt static lib
        // (scripts/fetch_wgpu_native.sh) or a locally built Dawn monolithic
        // dylib (scripts/stage_dawn_macos.sh).
        useDawnBackend
            ? .binaryTarget(
                name: "webgpu_backend",
                path: "Frameworks/webgpu_dawn.xcframework"
            )
            : .binaryTarget(
                name: "webgpu_backend",
                path: "Frameworks/wgpu_native.xcframework"
            ),
        // C/C++ bridge — SPM requires Swift and C++ in separate targets.
        // nitro headers (nitro.h, dart_api_dl.h …) are copied into include/
        // by `nitrogen link`, so no extra header search path is needed.
        .target(
            name: "NitroWebgpuCpp",
            dependencies: ["webgpu_backend"],
            path: "Sources/NitroWebgpuCpp",
            publicHeadersPath: "include",
            cxxSettings: cppSettings,
            linkerSettings: cppLinkerSettings
        ),
        // Present module C bridge — one Cpp target per Nitro module (the
        // generated Swift bridge imports NitroWebgpuPresentCpp). dart_api_dl.c
        // is compiled ONCE (in NitroWebgpuCpp) to avoid duplicate symbols.
        .target(
            name: "NitroWebgpuPresentCpp",
            path: "Sources/NitroWebgpuPresentCpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        // Swift implementation + generated bridge.
        .target(
            name: "nitro_webgpu",
            dependencies: [
                "NitroWebgpuCpp",
                "NitroWebgpuPresentCpp",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/NitroWebgpu"
        ),
    ]
)
