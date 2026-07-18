// Showcase suite: every gallery showcase must compile through the checked
// creates and render non-degenerate frames; interactive ones must react to
// the pointer; feedback simulations must evolve over time.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';
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
}
