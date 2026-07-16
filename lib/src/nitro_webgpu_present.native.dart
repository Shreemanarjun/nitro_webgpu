import 'package:nitro/nitro.dart';

part 'nitro_webgpu_present.g.dart';

/// Presentation module: hands frames rendered with the core [NitroWebgpu]
/// module to Flutter's texture registry.
///
/// The platform shims are thin — frame state and the wgpu readback path live
/// in shared C++ (`src/present/present_core.cpp`); Swift/Kotlin own only the
/// platform texture objects (CVPixelBuffer + FlutterTexture, SurfaceProducer).
///
/// M2.0 implements the portable CPU-readback presenter on macOS. Other
/// platforms are stubs until their milestone (Android M2.3, Windows M2.4,
/// Linux M2.5).
@NitroModule(
  ios: NativeImpl.swift,
  android: NativeImpl.kotlin,
  macos: NativeImpl.swift,
  windows: NativeImpl.cpp,
  linux: NativeImpl.cpp,
)
abstract class NitroWebgpuPresent extends HybridObject {
  static final NitroWebgpuPresent instance = _NitroWebgpuPresentImpl();

  /// Creates a presenter rendering at [widthPx]×[heightPx] physical pixels on
  /// the `WGPUDevice` at [deviceAddress]. Returns an opaque presenter token.
  int createPresenter(int deviceAddress, int widthPx, int heightPx);

  /// The Flutter texture id to pass to a `Texture` widget.
  int flutterTextureId(int token);

  /// Resolves with the `WGPUTextureView` address to render this frame into,
  /// or 0 to skip the frame (previous frame still in flight, resizing, or
  /// destroyed).
  @nitroNativeAsync
  Future<int> acquireFrame(int token);

  /// Hands the frame rendered into the last acquired view to Flutter.
  void presentFrame(int token);

  /// Raw `WGPUTextureFormat` of the render target (matches the platform
  /// compositor; bgra8unorm on Apple).
  int presenterFormat(int token);

  /// True when frames are presented on the GPU path (Metal blit on Apple);
  /// false for the CPU readback fallback.
  bool presenterUsesGpuPath(int token);

  /// Changes the RENDER resolution (what `acquireFrame` targets). Cheap on
  /// every platform — on Android the swapchain stays untouched and a scaled
  /// offscreen target is blitted at present.
  void resizePresenter(int token, int widthPx, int heightPx);

  /// Changes the on-screen SURFACE size (the widget's physical pixel box).
  /// Only meaningful on platforms presenting through a real window surface
  /// (Android swapchain — recreates it); a no-op on the ring presenters.
  void presenterSetSurfaceSize(int token, int widthPx, int heightPx);

  /// Drains in-flight GPU work, then tears down the presenter and
  /// unregisters the Flutter texture.
  @nitroNativeAsync
  Future<void> destroyPresenter(int token);
}
