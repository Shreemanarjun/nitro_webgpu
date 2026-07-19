// Showcase suite: every gallery showcase must compile through the checked
// creates and render non-degenerate frames; interactive ones must react to
// the pointer; feedback simulations must evolve over time.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';
import 'adapter_support.dart';
import 'package:nitro_webgpu_example/src/gpu/particle_scene.dart';
import 'package:nitro_webgpu_example/src/gpu/scenes.dart';
import 'package:nitro_webgpu_example/src/gpu/shadertoy_engine.dart';
import 'package:nitro_webgpu_example/src/showcase/showcase_gallery_page.dart';
import 'package:nitro_webgpu_example/src/showcase/showcases.dart';

const kForceFallback = bool.fromEnvironment('WGPU_FORCE_FALLBACK');
const _size = 64;

Future<Uint8List> renderFrames(
    GpuDevice device, GpuScene scene, List<Duration> steps) async {
  final target = device.createTexture(
    width: _size,
    height: _size,
    format: GpuTextureFormat.rgba8Unorm,
    usage: GpuTextureUsage.renderAttachment | GpuTextureUsage.copySrc,
  );
  final view = target.createView();
  final rt = GpuRenderTarget(
      view: view,
      width: _size,
      height: _size,
      targetFormat: GpuTextureFormat.rgba8Unorm);
  for (final t in steps) {
    await scene.render(device, rt, t);
  }
  final readback = device.createBuffer(
      size: 256 * _size,
      usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
  final encoder = device.createCommandEncoder();
  encoder.copyTextureToBuffer(target, readback, bytesPerRow: 256);
  device.queue.submit([encoder.finish()]);
  final pixels = await readback.mapRead();
  readback.dispose();
  view.dispose();
  target.dispose();
  return pixels;
}

List<int> pixelAt(Uint8List pixels, int x, int y) =>
    pixels.sublist(y * 256 + x * 4, y * 256 + x * 4 + 3).toList();

/// Samples an 8×8 grid and asserts the frame is neither empty nor flat:
/// at least [minDistinct] distinct colors and some non-black content.
void expectNonDegenerate(Uint8List pixels, String title,
    {int minDistinct = 3}) {
  final seen = <int>{};
  var maxChannel = 0;
  for (var gy = 0; gy < 8; gy++) {
    for (var gx = 0; gx < 8; gx++) {
      final p = pixelAt(pixels, gx * 8 + 4, gy * 8 + 4);
      seen.add((p[0] ~/ 8 << 12) | (p[1] ~/ 8 << 6) | (p[2] ~/ 8));
      maxChannel = [maxChannel, p[0], p[1], p[2]].reduce((a, b) => a > b ? a : b);
    }
  }
  expect(seen.length, greaterThanOrEqualTo(minDistinct),
      reason: '$title: expected varied output, got ${seen.length} colors');
  expect(maxChannel, greaterThan(16),
      reason: '$title: output is essentially black');
}

String? compileErrorOf(GpuScene scene) {
  if (scene is ShadertoyEngine) return scene.compileError.value;
  if (scene is ParticleScene) return scene.compileError.value;
  return null;
}

List<Duration> steps(int frames, {int fromMs = 0}) =>
    [for (var i = 1; i <= frames; i++) Duration(milliseconds: fromMs + 33 * i)];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('showcase gallery', () {
    for (final showcase in showcases) {
      test('"${showcase.title}" compiles and renders non-degenerate frames',
          () async {
        final adapter =
            await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
        final device = await adapter.requestDevice();
        final scene = showcase.build();
        if (scene is ParticleScene &&
            await skipWithoutCompute(device)) {
          scene.dispose();
          device.dispose();
          adapter.dispose();
          return;
        }
        // Enough frames for feedback sims to seed and evolve.
        final pixels = await renderFrames(device, scene, steps(12));
        expect(compileErrorOf(scene), isNull,
            reason: '"${showcase.title}" failed to compile');
        expectNonDegenerate(pixels, showcase.title);
        scene.dispose();
        device.dispose();
        adapter.dispose();
      });
    }

    test('interactive showcases react to the pointer', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      // Holographic card: the sheen must move with the pointer.
      final holo = showcases
          .firstWhere((s) => s.title == 'Holographic card')
          .build() as ShadertoyEngine;
      holo.setMouseNormalized(0.2, 0.2, press: true);
      final left = await renderFrames(device, holo, steps(2));
      holo.setMouseNormalized(0.8, 0.8);
      final right = await renderFrames(device, holo, steps(2, fromMs: 66));
      var diff = 0;
      for (var gy = 0; gy < 8; gy++) {
        for (var gx = 0; gx < 8; gx++) {
          final a = pixelAt(left, gx * 8 + 4, gy * 8 + 4);
          final b = pixelAt(right, gx * 8 + 4, gy * 8 + 4);
          diff += (a[0] - b[0]).abs() + (a[1] - b[1]).abs() +
              (a[2] - b[2]).abs();
        }
      }
      expect(diff, greaterThan(200),
          reason: 'pointer move should change the holographic sheen');
      holo.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('feedback simulations evolve over time', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      // Fog of war: revealed area only grows as the explorer moves.
      final fog =
          showcases.firstWhere((s) => s.title == 'Fog of war').build();
      final early = await renderFrames(device, fog, steps(4));
      final late_ = await renderFrames(device, fog, steps(60, fromMs: 132));
      int litCells(Uint8List px) {
        var lit = 0;
        for (var gy = 0; gy < 8; gy++) {
          for (var gx = 0; gx < 8; gx++) {
            final p = pixelAt(px, gx * 8 + 4, gy * 8 + 4);
            if (p[0] + p[1] + p[2] > 90) lit++;
          }
        }
        return lit;
      }

      expect(litCells(late_), greaterThan(litCells(early)),
          reason: 'exploration must reveal more terrain over time');
      fog.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('boids stay in bounds and keep moving', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      if (await skipWithoutCompute(device)) {
        device.dispose();
        adapter.dispose();
        return;
      }
      final scene = showcases
          .firstWhere((s) => s.title == 'Boids flocking')
          .build() as ParticleScene;
      await renderFrames(device, scene, steps(30));
      final staging = device.createBuffer(
          size: scene.count * 16,
          usage: GpuBufferUsage.mapRead | GpuBufferUsage.copyDst);
      final encoder = device.createCommandEncoder();
      encoder.copyBufferToBuffer(scene.particleBuffer!, staging);
      device.queue.submit([encoder.finish()]);
      final data = Float32List.view((await staging.mapRead()).buffer);
      var moving = 0;
      for (var i = 0; i < scene.count; i++) {
        expect(data[i * 4].abs(), lessThanOrEqualTo(1.01),
            reason: 'boid $i x in bounds');
        expect(data[i * 4 + 1].abs(), lessThanOrEqualTo(1.01),
            reason: 'boid $i y in bounds');
        final speed = data[i * 4 + 2].abs() + data[i * 4 + 3].abs();
        if (speed > 0.01) moving++;
      }
      expect(moving, greaterThan(scene.count ~/ 2),
          reason: 'most boids should be in motion');
      staging.dispose();
      scene.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('Breakout: paddle tracks the pointer and the ball moves', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final game = showcases
          .firstWhere((s) => s.title == 'Breakout (GPU game)')
          .build() as ShadertoyEngine;

      // Paddle band: uv.y ∈ (0.055, 0.075) → shadertoy fragCoord.y ≈ 4.2
      // → memory row 63.5 - 4.2 ≈ 59 (framebuffer origin is top-left).
      List<int> paddleRow(Uint8List px, int x) => pixelAt(px, x, 59);

      game.setMouseNormalized(0.2, 0.5, press: true);
      final left = await renderFrames(device, game, steps(3));
      expect(paddleRow(left, (0.2 * _size).round())[2], greaterThan(150),
          reason: 'paddle bright under the pointer at x=0.2');
      expect(paddleRow(left, (0.8 * _size).round())[2], lessThan(120),
          reason: 'no paddle at x=0.8 while the pointer is at 0.2');

      game.setMouseNormalized(0.8, 0.5);
      final right = await renderFrames(device, game, steps(3, fromMs: 99));
      expect(paddleRow(right, (0.8 * _size).round())[2], greaterThan(150),
          reason: 'paddle follows the pointer to x=0.8');

      // The ball's glow must move between two spaced frames.
      final a = await renderFrames(device, game, steps(1, fromMs: 198));
      final b = await renderFrames(device, game, steps(8, fromMs: 231));
      var diff = 0;
      for (var gy = 1; gy < 7; gy++) {
        for (var gx = 0; gx < 8; gx++) {
          final p1 = pixelAt(a, gx * 8 + 4, gy * 8 + 4);
          final p2 = pixelAt(b, gx * 8 + 4, gy * 8 + 4);
          diff += (p1[0] - p2[0]).abs() + (p1[1] - p2[1]).abs();
        }
      }
      expect(diff, greaterThan(60), reason: 'ball glow moved between frames');
      game.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('Breakout: brick wall renders in the top band', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final game = showcases
          .firstWhere((s) => s.title == 'Breakout (GPU game)')
          .build();
      final pixels = await renderFrames(device, game, steps(4));
      // Brick band: uv.y in 0.60..0.92 → rows ~5..25 after the flip. Expect
      // colorful (non-background) pixels there.
      // Brick band spans memory rows ~5..25; scan it (single rows can land
      // in the gaps between brick rows).
      var colorful = 0;
      for (var y = 5; y <= 25; y++) {
        for (var gx = 0; gx < 8; gx++) {
          final p = pixelAt(pixels, gx * 8 + 4, y);
          if (p[0] + p[1] + p[2] > 120) colorful++;
        }
      }
      expect(colorful, greaterThanOrEqualTo(16),
          reason: 'brick wall visible across the band');
      game.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('Racer: steering keys move the car across the track', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final racer = showcases
          .firstWhere((s) => s.title == '3D racer (keyboard)')
          .build() as ShadertoyEngine;

      // Player car row: carY uv 0.115 → memory row ≈ 63.5 - 7.36 ≈ 56.
      // The body is magenta (r and b high) — nothing else on screen is.
      double carColumn(Uint8List px) {
        var sum = 0.0;
        var n = 0;
        for (var y = 54; y <= 58; y++) {
          for (var x = 0; x < _size; x++) {
            final p = pixelAt(px, x, y);
            if (p[0] > 180 && p[2] > 160 && p[1] < 90) {
              sum += x;
              n++;
            }
          }
        }
        expect(n, greaterThan(0), reason: 'player car visible');
        return sum / n;
      }

      final neutral = carColumn(await renderFrames(device, racer, steps(6)));
      racer.setKey(ShadertoyKey.left, true);
      final steered =
          carColumn(await renderFrames(device, racer, steps(30, fromMs: 198)));
      racer.setKey(ShadertoyKey.left, false);
      expect(steered, lessThan(neutral - 2),
          reason: 'holding left moves the car left '
              '(neutral $neutral → steered $steered)');
      racer.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('Racer: throttle animates the road, braking stops it', () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final racer = showcases
          .firstWhere((s) => s.title == '3D racer (keyboard)')
          .build() as ShadertoyEngine;

      int roadDiff(Uint8List a, Uint8List b) {
        var diff = 0;
        // Road region: memory rows 30..50, avoiding the car and the HUD.
        for (var y = 30; y <= 50; y += 2) {
          for (var x = 4; x < _size; x += 4) {
            final p1 = pixelAt(a, x, y);
            final p2 = pixelAt(b, x, y);
            diff += (p1[0] - p2[0]).abs() +
                (p1[1] - p2[1]).abs() +
                (p1[2] - p2[2]).abs();
          }
        }
        return diff;
      }

      racer.setKey(ShadertoyKey.up, true);
      await renderFrames(device, racer, steps(30));
      final fastA = await renderFrames(device, racer, steps(1, fromMs: 990));
      final fastB = await renderFrames(device, racer, steps(1, fromMs: 1023));
      final movingDiff = roadDiff(fastA, fastB);
      racer.setKey(ShadertoyKey.up, false);
      racer.setKey(ShadertoyKey.down, true);
      await renderFrames(device, racer, steps(60, fromMs: 1056));
      final stopA = await renderFrames(device, racer, steps(1, fromMs: 3036));
      final stopB = await renderFrames(device, racer, steps(1, fromMs: 3069));
      final stoppedDiff = roadDiff(stopA, stopB);
      expect(movingDiff, greaterThan(stoppedDiff * 2 + 50),
          reason: 'road animates under throttle ($movingDiff) and freezes '
              'when braked to a stop ($stoppedDiff)');
      racer.dispose();
      device.dispose();
      adapter.dispose();
    });

    test('Racer: endless score ticks and a collision ends the run',
        () async {
      final adapter =
          await Gpu.requestAdapter(forceFallbackAdapter: kForceFallback);
      final device = await adapter.requestDevice();
      final racer = showcases
          .firstWhere((s) => s.title == '3D racer (keyboard)')
          .build() as ShadertoyEngine;
      var t = 0;
      List<Duration> more(int frames) =>
          [for (var i = 0; i < frames; i++) Duration(milliseconds: t += 33)];

      // Score HUD (top-right digits, memory rows 3..5) ticks while driving.
      racer.setKey(ShadertoyKey.up, true);
      final hudA = await renderFrames(device, racer, more(20));
      final hudB = await renderFrames(device, racer, more(6));
      int hudDiff(Uint8List a, Uint8List b) {
        var d = 0;
        for (var y = 2; y <= 6; y++) {
          for (var x = 40; x < 62; x++) {
            d += (pixelAt(a, x, y)[0] - pixelAt(b, x, y)[0]).abs();
          }
        }
        return d;
      }

      expect(hudDiff(hudA, hudB), greaterThan(30),
          reason: 'score digits change while driving');

      // Keep driving until a rival ends the run: GAME OVER title renders
      // as red text around memory rows 18..25 (deterministic hash road).
      bool dead(Uint8List px) {
        var red = 0;
        for (var y = 18; y <= 25; y++) {
          for (var x = 8; x < 56; x += 2) {
            final p = pixelAt(px, x, y);
            if (p[0] > 140 && p[1] < 80 && p[2] < 80) red++;
          }
        }
        return red >= 4;
      }

      var frame = hudB;
      var chunks = 0;
      while (!dead(frame) && chunks < 12) {
        frame = await renderFrames(device, racer, more(60));
        chunks++;
      }
      expect(dead(frame), isTrue,
          reason: 'a collision must end the run within ~24 s of driving');

      // Dead: the world freezes (road region static) even with throttle
      // held, and a HELD key must NOT restart (fresh press required).
      final frozenA = await renderFrames(device, racer, more(2));
      final frozenB = await renderFrames(device, racer, more(2));
      int roadDiff(Uint8List a, Uint8List b) {
        var d = 0;
        for (var y = 30; y <= 45; y += 2) {
          for (var x = 4; x < 60; x += 4) {
            final p1 = pixelAt(a, x, y);
            final p2 = pixelAt(b, x, y);
            d += (p1[0] - p2[0]).abs() + (p1[1] - p2[1]).abs();
          }
        }
        return d;
      }

      expect(roadDiff(frozenA, frozenB), lessThan(40),
          reason: 'world frozen after game over despite held throttle');

      // Fresh press: release, settle the latch, press again → new run.
      racer.setKey(ShadertoyKey.up, false);
      await renderFrames(device, racer, more(4));
      racer.setKey(ShadertoyKey.up, true);
      final restartA = await renderFrames(device, racer, more(12));
      expect(dead(restartA), isFalse, reason: 'restarted after fresh press');
      final restartB = await renderFrames(device, racer, more(3));
      expect(roadDiff(restartA, restartB), greaterThan(60),
          reason: 'road animates again after restart');
      racer.setKey(ShadertoyKey.up, false);
      racer.dispose();
      device.dispose();
      adapter.dispose();
    });

    testWidgets('Racer viewer wires the keyboard to the engine',
        (tester) async {
      final binding = tester.binding as LiveTestWidgetsFlutterBinding;
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

      await tester.pumpWidget(MaterialApp(
        home: ShowcaseViewerPage(
            showcase: showcases
                .firstWhere((s) => s.title == '3D racer (keyboard)')),
      ));
      await tester.pump();
      final state = tester.state<ShowcaseViewerPageState>(
          find.byType(ShowcaseViewerPage));
      final engine = state.sceneForTesting as ShadertoyEngine;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(engine.debugKeys[0], 1.0, reason: 'ArrowLeft pressed');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(engine.debugKeys[0], 0.0, reason: 'ArrowLeft released');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.pump();
      expect(engine.debugKeys[2], 1.0, reason: 'W maps to throttle');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pump();
    });

    testWidgets('gallery page lists every showcase and opens the viewer',
        (tester) async {
      final binding = tester.binding as LiveTestWidgetsFlutterBinding;
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

      await tester.pumpWidget(const MaterialApp(home: ShowcaseGalleryPage()));
      await tester.pump();
      expect(find.text('Mesh gradient'), findsOneWidget);

      // Fullscreen viewer renders a live interactive showcase.
      await tester.pumpWidget(MaterialApp(
        home: ShowcaseViewerPage(
            showcase:
                showcases.firstWhere((s) => s.title == 'Holographic card')),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump();

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pump();
    });
  });

  group('high-level widgets', () {
    testWidgets('WebGpuShaderView renders live with zero setup',
        (tester) async {
      final binding = tester.binding as LiveTestWidgetsFlutterBinding;
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

      String? reported;
      await tester.pumpWidget(MaterialApp(
          home: WebGpuShaderView(onError: (m) => reported = m)));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump();
      expect(find.byType(WebGpuShaderView), findsOneWidget);
      // The built-in demo fragment must compile and validate cleanly.
      expect(reported, isNull,
          reason: 'unexpected shader-view error: $reported');

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pump();
    });

    testWidgets('WebGpuShaderView surfaces compile errors and keeps running',
        (tester) async {
      final binding = tester.binding as LiveTestWidgetsFlutterBinding;
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

      String? reported;
      await tester.pumpWidget(MaterialApp(
        home: WebGpuShaderView(
          fragment: 'this is not wgsl',
          onError: (m) => reported = m,
        ),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pump();
      expect(reported, isNotNull,
          reason: 'compiler diagnostics reach onError');

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 600)));
      await tester.pump();
    });

    testWidgets('WebGpuBuilder hands out the shared device', (tester) async {
      GpuDevice? received;
      await tester.pumpWidget(MaterialApp(
        home: WebGpuBuilder(builder: (context, device) {
          received = device;
          return const SizedBox();
        }),
      ));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 800)));
      await tester.pump();
      expect(received, isNotNull);
      expect(identical(received, await WebGpu.device()), isTrue,
          reason: 'WebGpuBuilder serves the app-lifetime shared device');
    });
  });
}
