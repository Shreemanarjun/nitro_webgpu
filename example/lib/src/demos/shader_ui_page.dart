import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nitro_webgpu/nitro_webgpu.dart';

/// Aurora bands over a starfield, mouse-reactive. Dark on purpose — the
/// point of this page is white Flutter UI composited on top.
const _aurora = '''
fn hash(p: vec2f) -> f32 {
  return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

fn noise(p: vec2f) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2f(1.0, 0.0)), u.x),
             mix(hash(i + vec2f(0.0, 1.0)), hash(i + vec2f(1.0, 1.0)), u.x),
             u.y);
}

fn fbm(p0: vec2f) -> f32 {
  var v = 0.0;
  var a = 0.5;
  var p = p0;
  for (var i = 0; i < 5; i = i + 1) {
    v += a * noise(p);
    p *= 2.0;
    a *= 0.5;
  }
  return v;
}

@fragment
fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let uv = pos.xy / nw.resolution;
  let aspect = nw.resolution.x / nw.resolution.y;
  var col = vec3f(0.02, 0.03, 0.08);

  // Three drifting aurora bands.
  for (var i = 0; i < 3; i = i + 1) {
    let fi = f32(i);
    let drift = fbm(vec2f(uv.x * 3.0 + nw.time * (0.15 + 0.07 * fi),
                          fi * 7.0 + nw.time * 0.1));
    let y = uv.y - 0.35 - 0.18 * fi + 0.12 * drift;
    let band = exp(-y * y * 60.0);
    let hue = vec3f(0.1 + 0.3 * fi, 0.9 - 0.25 * fi, 0.7 + 0.15 * fi);
    col += band * hue * (0.35 + 0.2 * sin(nw.time * 0.5 + fi));
  }

  // Soft glow that follows the pointer.
  let m = nw.mouse / nw.resolution;
  let d = distance(uv * vec2f(aspect, 1.0), m * vec2f(aspect, 1.0));
  col += vec3f(0.2, 0.5, 0.9) * exp(-d * d * 8.0) * 0.35;

  // Twinkling stars.
  let s = hash(floor(pos.xy / 2.0));
  col += vec3f(step(0.997, s)) * 0.6 * (0.5 + 0.5 * sin(nw.time * 3.0 + s * 40.0));

  let vignette = smoothstep(1.2, 0.4, length(uv - 0.5) * 1.6);
  return vec4f(col * vignette, 1.0);
}
''';

/// Paints a translucent scrim over the whole view with the clock glyphs
/// knocked out — the shader beneath shows through the text at full
/// brightness. The glyphs are drawn as a plain mask and the scrim rect is
/// blended over them with [BlendMode.srcOut]; blending the *text* instead
/// (e.g. a clear/srcOut foreground Paint) renders glyph-atlas squares on
/// Impeller (iOS).
class _ClockKnockout extends CustomPainter {
  _ClockKnockout(this.text);

  final String text;

  @override
  void paint(Canvas canvas, Size size) {
    // "01:57:50" at w800 is ~5.2 em wide — size to the view with margins,
    // capped for desktop windows.
    final fontSize = ((size.width - 48) / 5.2).clamp(40.0, 110.0);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          letterSpacing: fontSize / 48,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Offset.zero & size;
    canvas.saveLayer(rect, Paint());
    tp.paint(
        canvas,
        Offset((size.width - tp.width) / 2,
            size.height * 0.35 - tp.height / 2));
    canvas.drawRect(
        rect,
        Paint()
          ..color = const Color(0xC8060A14)
          ..blendMode = BlendMode.srcOut);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ClockKnockout oldDelegate) => oldDelegate.text != text;
}

/// Ordinary Flutter UI — a ticking Material clock, buttons, chips —
/// stacked over a [WebGpuShaderView]. The GPU view is a normal widget, so
/// composition, hit testing, and per-second rebuilds all just work.
class ShaderUiPage extends StatefulWidget {
  const ShaderUiPage({super.key});

  @override
  State<ShaderUiPage> createState() => _ShaderUiPageState();
}

class _ShaderUiPageState extends State<ShaderUiPage> {
  final _controller = WebGpuShaderViewController();
  late final Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    // The once-a-second rebuild for the clock also refreshes the fps chip;
    // the shader view underneath is untouched by rebuilds.
    _timer = Timer.periodic(
        const Duration(seconds: 1), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final time = '${_two(_now.hour)}:${_two(_now.minute)}:${_two(_now.second)}';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final date = '${days[_now.weekday - 1]}, '
        '${months[_now.month - 1]} ${_now.day} ${_now.year}';
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Shaders behind Flutter UI'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          WebGpuShaderView(fragment: _aurora, controller: _controller),
          // Shader-filled text: a translucent scrim with the clock glyphs
          // erased out of it, so the aurora shows dimmed around the text
          // and at full brightness *through* the glyphs.
          IgnorePointer(
            child: Semantics(
              label: 'clock',
              child: CustomPaint(
                key: const ValueKey('clock-knockout'),
                painter: _ClockKnockout(time),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              // Sits below the knockout clock (centered at 0.35 of the
              // height) on any screen size — no fixed spacers.
              alignment: const Alignment(0, 0.45),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(date,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 18)),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () => setState(() => _controller.isPaused
                            ? _controller.resume()
                            : _controller.pause()),
                        icon: Icon(_controller.isPaused
                            ? Icons.play_arrow
                            : Icons.pause),
                        label: Text(_controller.isPaused
                            ? 'Resume shader'
                            : 'Pause shader'),
                      ),
                      Chip(
                        avatar: const Icon(Icons.speed, size: 18),
                        label: Text('${_controller.fps.round()} fps'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      'The clock glyphs are windows into the shader — drag '
                      'anywhere and the aurora follows, brightest inside '
                      'the text.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
