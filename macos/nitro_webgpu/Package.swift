// swift-tools-version: 5.9
import PackageDescription

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
        // wgpu-native prebuilt static lib (scripts/fetch_wgpu_native.sh).
        .binaryTarget(
            name: "wgpu_native",
            path: "Frameworks/wgpu_native.xcframework"
        ),
        // C/C++ bridge — SPM requires Swift and C++ in separate targets.
        // nitro headers (nitro.h, dart_api_dl.h …) are copied into include/
        // by `nitrogen link`, so no extra header search path is needed.
        .target(
            name: "NitroWebgpuCpp",
            dependencies: ["wgpu_native"],
            path: "Sources/NitroWebgpuCpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-std=c++17"])
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
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
