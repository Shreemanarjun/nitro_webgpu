// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nitro_webgpu",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "nitro-webgpu", targets: ["nitro_webgpu"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        // C/C++ bridge — SPM requires Swift and C++ in separate targets.
        // nitro headers (nitro.h, dart_api_dl.h …) are copied into include/
        // by `nitrogen link`, so no extra header search path is needed.
        .target(
            name: "NitroWebgpuCpp",
            path: "Sources/NitroWebgpuCpp",
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
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/NitroWebgpu"
        ),
    ]
)
