import 'package:nitro/nitro.dart';

part 'nitro_webgpu.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift, windows: NativeImpl.cpp, linux: NativeImpl.cpp)
abstract class NitroWebgpu extends HybridObject {
  static final NitroWebgpu instance = _NitroWebgpuImpl();

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);
}
