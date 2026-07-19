// SCRATCH — visual repro harness, not part of the suite. Holds the real
// ParticlesPage live on screen long enough for a host-side `adb screencap`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_webgpu_example/src/demos/particles_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scratch: particles page held on screen', (tester) async {
    final binding = tester.binding as LiveTestWidgetsFlutterBinding;
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

    await tester.pumpWidget(const MaterialApp(home: ParticlesPage()));
    // Long real-time window: the host screencaps the emulator meanwhile.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 25)));
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
