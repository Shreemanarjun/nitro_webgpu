import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

const _sunset = '''
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let uv = pos.xy / nw.resolution;
  let y = uv.y + 0.08 * sin(uv.x * 8.0 + nw.time * 1.2)
      + 0.04 * sin(uv.x * 19.0 - nw.time * 0.7);
  let sky = mix(vec3f(0.98, 0.55, 0.25), vec3f(0.35, 0.12, 0.42), y);
  let sun = exp(-distance(uv, vec2f(0.5, 0.42)) * 5.0);
  return vec4f(sky + vec3f(1.0, 0.8, 0.5) * sun * 0.6, 1.0);
}
''';

const _rings = '''
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let res = nw.resolution;
  let p = (pos.xy - 0.5 * res) / res.y;
  let d = length(p);
  var col = vec3f(0.02, 0.01, 0.05);
  let ring = pow(0.5 + 0.5 * sin(d * 30.0 - nw.time * 3.0), 8.0);
  col += ring * mix(vec3f(0.1, 0.9, 0.9), vec3f(0.8, 0.2, 1.0), d * 1.5);
  col *= exp(-d * 1.2);
  return vec4f(col, 1.0);
}
''';

const _ripple = '''
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let res = nw.resolution;
  let uv = pos.xy / res;
  let m = select(vec2f(0.5, 0.5), nw.mouse / res, nw.mouse.x > 0.0);
  let asp = vec2f(res.x / res.y, 1.0);
  let d = distance(uv * asp, m * asp);
  let wave = sin(d * 40.0 - nw.time * 5.0) * exp(-d * 3.0);
  let base = mix(vec3f(0.05, 0.15, 0.3), vec3f(0.1, 0.5, 0.7),
      uv.y + 0.2 * wave);
  let hl = (0.5 + 0.5 * wave) * exp(-d * 2.5) * (0.4 + 0.6 * nw.mouseDown);
  return vec4f(base + vec3f(0.4, 0.9, 1.0) * hl * 0.5, 1.0);
}
''';

const _plasma = '''
@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let uv = pos.xy / nw.resolution;
  let t = nw.time;
  var v = sin(uv.x * 10.0 + t);
  v += sin((uv.y * 10.0 + t) * 0.5);
  v += sin((uv.x + uv.y) * 5.0 + t * 0.8);
  let cx = uv.x + 0.5 * sin(t / 5.0);
  let cy = uv.y + 0.5 * cos(t / 3.0);
  v += sin(sqrt(cx * cx + cy * cy + 1.0) * 10.0 + t);
  let pi = 3.14159;
  let col = vec3f(0.5 + 0.5 * sin(v * pi),
                  0.5 + 0.5 * sin(v * pi + 2.09),
                  0.5 + 0.5 * sin(v * pi + 4.18));
  return vec4f(col * 0.85, 1.0);
}
''';

/// Animated shader backgrounds as ordinary Material cards — the everyday
/// use of [WebGpuShaderView]: hero headers, list tiles, banners. Four
/// independent views render in one scrolling list; they all share the
/// app-lifetime device behind the scenes.
class ShaderCardsPage extends StatelessWidget {
  const ShaderCardsPage({super.key, this.onShaderError});

  /// Surfaces any card's compile error (used by tests).
  final void Function(String card, String message)? onShaderError;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shader cards')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ShaderCard(
            title: 'Sunset waves',
            subtitle: 'A hero header in one fragment',
            fragment: _sunset,
            height: 200,
            onError: onShaderError,
          ),
          _ShaderCard(
            title: 'Touch ripple',
            subtitle: 'Tap or drag — nw.mouse drives the rings',
            fragment: _ripple,
            height: 150,
            onError: onShaderError,
          ),
          _ShaderCard(
            title: 'Neon pulse',
            subtitle: 'Signed-distance rings, two-line WGSL',
            fragment: _rings,
            height: 150,
            onError: onShaderError,
          ),
          _ShaderCard(
            title: 'Plasma',
            subtitle: 'The classic, at display refresh rate',
            fragment: _plasma,
            height: 150,
            onError: onShaderError,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Each card is a WebGpuShaderView inside a Card — no setup, '
              'no controllers, one shared GPU device.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShaderCard extends StatelessWidget {
  const _ShaderCard({
    required this.title,
    required this.subtitle,
    required this.fragment,
    required this.height,
    this.onError,
  });

  final String title;
  final String subtitle;
  final String fragment;
  final double height;
  final void Function(String card, String message)? onError;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 16),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            WebGpuShaderView(
              fragment: fragment,
              onError:
                  onError == null ? null : (m) => onError!(title, m),
            ),
            // Legibility scrim behind the labels.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.55, 1.0],
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
