// One-command native-binary setup, runnable from any app that depends on
// this package:
//
//   dart run nitro_webgpu:setup            # host-appropriate targets
//   dart run nitro_webgpu:setup --targets macos-aarch64,ios-aarch64-simulator
//
// Only Apple platforms need this (xcframework assembly requires xcodebuild);
// Android/Windows/Linux builds auto-vendor the binaries at build time via
// CMake with the same pinned checksums.
import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> args) async {
  if (Platform.isWindows) {
    stdout.writeln(
        'nitro_webgpu: nothing to do on Windows — Windows/Linux/Android '
        'builds vendor wgpu-native automatically at build time.');
    return;
  }
  final marker = await Isolate.resolvePackageUri(
      Uri.parse('package:nitro_webgpu/nitro_webgpu.dart'));
  if (marker == null) {
    stderr.writeln('nitro_webgpu: package not resolvable — run this from an '
        'app that depends on nitro_webgpu.');
    exitCode = 1;
    return;
  }
  final packageRoot =
      File.fromUri(marker).parent.parent.path; // lib/ -> package root
  final script = '$packageRoot/scripts/fetch_wgpu_native.sh';
  if (!File(script).existsSync()) {
    stderr.writeln('nitro_webgpu: $script not found.');
    exitCode = 1;
    return;
  }
  final process = await Process.start('bash', [script, ...args],
      mode: ProcessStartMode.inheritStdio);
  exitCode = await process.exitCode;
}
