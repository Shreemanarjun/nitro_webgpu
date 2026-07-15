import 'shader_presets.dart';
import 'scenes.dart';

/// Four deliberately heavy scenes for the performance benchmark: each one
/// stresses the GPU differently (raymarch + reflections, distance-estimated
/// fractal, ALU-heavy noise, many-body field evaluation).
List<(String, GpuScene Function())> benchmarkScenes() => [
      ('Neon cubes (raymarch)', NeonCubesScene.new),
      ('Mandelbulb (fractal DE)', MandelbulbScene.new),
      ('FBM domain warp (noise)', FbmWarpScene.new),
      ('Metaballs (field eval)', MetaballsScene.new),
    ];

/// The mslfR2 raymarcher — one-bounce reflections, glow, procedural sky.
class NeonCubesScene extends UniformScene {
  @override
  String get name => 'neon-cubes';

  @override
  String get wgsl => cubesPreset.source;
}

/// Power-8 Mandelbulb via distance estimation — 96 march steps with 6-fold
/// nested trig per DE evaluation, plus 6 more DEs for the normal.
class MandelbulbScene extends UniformScene {
  @override
  String get name => 'mandelbulb';

  @override
  double get param => 0.4;

  @override
  String get wgsl => r'''
struct U { time: f32, width: f32, height: f32, param: f32 };
@group(0) @binding(0) var<uniform> u: U;

fn rotY3(a: f32) -> mat3x3f {
  let c = cos(a);
  let s = sin(a);
  return mat3x3f(c, 0.0, s, 0.0, 1.0, 0.0, -s, 0.0, c);
}

fn mandelbulbDE(p0: vec3f) -> f32 {
  var z = p0;
  var dr = 1.0;
  var r = length(z);
  for (var i = 0; i < 6; i++) {
    r = length(z);
    if (r > 2.0) { break; }
    let rr = max(r, 1e-4);
    let theta = acos(clamp(z.z / rr, -1.0, 1.0)) * 8.0;
    let phi = atan2(z.y, z.x) * 8.0;
    let zr = pow(rr, 8.0);
    dr = pow(rr, 7.0) * 8.0 * dr + 1.0;
    z = zr * vec3f(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)) + p0;
  }
  return 0.25 * log(max(r, 1e-4)) * r / dr;
}

fn bulbNormal(p: vec3f) -> vec3f {
  let e = 0.0008;
  return normalize(vec3f(
      mandelbulbDE(p + vec3f(e, 0.0, 0.0)) - mandelbulbDE(p - vec3f(e, 0.0, 0.0)),
      mandelbulbDE(p + vec3f(0.0, e, 0.0)) - mandelbulbDE(p - vec3f(0.0, e, 0.0)),
      mandelbulbDE(p + vec3f(0.0, 0.0, e)) - mandelbulbDE(p - vec3f(0.0, 0.0, e))));
}

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
  let res = vec2f(u.width, u.height);
  let p = (2.0 * frag.xy - res) / res.y * vec2f(1.0, -1.0);
  let rot = rotY3(u.time * 0.35);
  let zoom = mix(2.6, 1.8, u.param);
  let ro = rot * vec3f(0.0, 0.15, -zoom);
  let rd = rot * normalize(vec3f(p, 1.6));

  var t = 0.0;
  var hit = false;
  var steps = 0.0;
  for (var i = 0; i < 96; i++) {
    let d = mandelbulbDE(ro + rd * t);
    if (d < 0.0008) { hit = true; break; }
    if (t > 6.0) { break; }
    t += d;
    steps += 1.0;
  }

  var col = vec3f(0.02, 0.02, 0.05) + 0.06 * vec3f(0.4, 0.5, 1.0) * length(p);
  if (hit) {
    let hp = ro + rd * t;
    let n = bulbNormal(hp);
    let ldir = normalize(vec3f(0.6, 0.7, -0.4));
    let dif = max(dot(n, ldir), 0.0);
    let rim = pow(1.0 + dot(n, rd), 3.0);
    let ao = 1.0 - steps / 96.0;
    let base = mix(vec3f(0.9, 0.4, 0.2), vec3f(0.3, 0.5, 0.95),
                   0.5 + 0.5 * sin(6.0 * length(hp) + u.time));
    col = base * (0.15 + dif) * ao + vec3f(0.6, 0.7, 1.0) * rim * 0.4;
  }
  col = pow(col, vec3f(0.4545));
  return vec4f(col, 1.0);
}
''';
}

/// Triple-layer domain-warped fBm — 18 six-octave noise evaluations/pixel.
class FbmWarpScene extends UniformScene {
  @override
  String get name => 'fbm-warp';

  @override
  double get param => 0.35;

  @override
  String get wgsl => r'''
struct U { time: f32, width: f32, height: f32, param: f32 };
@group(0) @binding(0) var<uniform> u: U;

fn hash21(p: vec2f) -> f32 {
  var q = fract(p * vec2f(123.34, 456.21));
  q += dot(q, q + 45.32);
  return fract(q.x * q.y);
}

fn vnoise(p: vec2f) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let w = f * f * (3.0 - 2.0 * f);
  let a = hash21(i);
  let b = hash21(i + vec2f(1.0, 0.0));
  let c = hash21(i + vec2f(0.0, 1.0));
  let d = hash21(i + vec2f(1.0, 1.0));
  return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

fn fbm(p_in: vec2f) -> f32 {
  var p = p_in;
  var v = 0.0;
  var amp = 0.5;
  let rot = mat2x2f(0.8, 0.6, -0.6, 0.8);
  for (var i = 0; i < 6; i++) {
    v += amp * vnoise(p);
    p = rot * p * 2.02;
    amp *= 0.5;
  }
  return v;
}

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
  let res = vec2f(u.width, u.height);
  let p = frag.xy / res.y * (2.0 + 3.0 * u.param);
  let t = u.time * 0.15;

  // Three layers of domain warping — 18 fbm evaluations per pixel.
  let q = vec2f(fbm(p + t), fbm(p + vec2f(5.2, 1.3) - t));
  let r = vec2f(fbm(p + 4.0 * q + vec2f(1.7, 9.2) + t),
                fbm(p + 4.0 * q + vec2f(8.3, 2.8) - t));
  let f = fbm(p + 4.0 * r);

  var col = mix(vec3f(0.10, 0.08, 0.35), vec3f(0.95, 0.55, 0.25),
                clamp(f * f * 3.2, 0.0, 1.0));
  col = mix(col, vec3f(0.15, 0.75, 0.65), clamp(length(q), 0.0, 1.0) * 0.6);
  col = mix(col, vec3f(0.9, 0.9, 1.0), clamp(r.x * r.x, 0.0, 1.0) * 0.4);
  col *= 0.6 + 0.9 * f;
  col = pow(col, vec3f(0.4545));
  return vec4f(col, 1.0);
}
''';
}

/// 18 metaballs with gradient-based shading — 54 field terms per pixel.
class MetaballsScene extends UniformScene {
  @override
  String get name => 'metaballs';

  @override
  double get param => 0.3;

  @override
  String get wgsl => r'''
struct U { time: f32, width: f32, height: f32, param: f32 };
@group(0) @binding(0) var<uniform> u: U;

const BALLS: i32 = 18;

fn ballPos(i: f32, t: f32) -> vec2f {
  let a = t * (0.3 + 0.05 * i) + i * 2.399;
  let r = 0.25 + 0.45 * fract(sin(i * 12.9898) * 43758.5453);
  return vec2f(cos(a), sin(a * 1.3 + i)) * r;
}

fn field(p: vec2f, t: f32) -> f32 {
  var f = 0.0;
  for (var i = 0; i < BALLS; i++) {
    let fi = f32(i);
    let d = p - ballPos(fi, t);
    let r2 = 0.006 + 0.004 * fract(sin(fi * 78.233) * 12543.123);
    f += r2 / (dot(d, d) + 1e-5);
  }
  return f;
}

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
  let res = vec2f(u.width, u.height);
  let p = (2.0 * frag.xy - res) / res.y;
  let t = u.time;

  let f = field(p, t);
  // Screen-space gradient of the field for fake 3D shading (2 extra evals).
  let e = 0.004;
  let gx = field(p + vec2f(e, 0.0), t) - f;
  let gy = field(p + vec2f(0.0, e), t) - f;
  let n = normalize(vec3f(-gx, -gy, e * 6.0));

  let iso = 1.0 + 0.8 * u.param;
  let m = smoothstep(iso - 0.06, iso + 0.06, f);
  let ldir = normalize(vec3f(0.5, 0.7, 0.6));
  let dif = max(dot(n, ldir), 0.0);
  let spec = pow(max(dot(reflect(-ldir, n), vec3f(0.0, 0.0, 1.0)), 0.0), 24.0);

  let goo = mix(vec3f(0.05, 0.45, 0.55), vec3f(0.55, 0.15, 0.75),
                0.5 + 0.5 * sin(f * 2.0 + t * 0.7));
  var col = vec3f(0.03, 0.03, 0.06) + 0.05 * vec3f(f * 0.4);
  col = mix(col, goo * (0.25 + dif) + vec3f(spec), m);
  col = pow(col, vec3f(0.4545));
  return vec4f(col, 1.0);
}
''';
}
