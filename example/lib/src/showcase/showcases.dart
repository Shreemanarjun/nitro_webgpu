import 'dart:typed_data';

import '../gpu/particle_scene.dart';
import '../gpu/scenes.dart';
import '../gpu/shadertoy_engine.dart';

/// One showcase entry: a real-world shader technique as a ready scene.
class Showcase {
  const Showcase({
    required this.title,
    required this.description,
    required this.category,
    required this.build,
    this.interactive = false,
    this.keyboard = false,
  });

  final String title;
  final String description;
  final String category;
  final GpuScene Function() build;

  /// True when the scene reacts to pointer input (iMouse).
  final bool interactive;

  /// True when the scene is driven by the keyboard (iKeys).
  final bool keyboard;
}

ShadertoyEngine _image(String wgsl) => ShadertoyEngine(
      image: ShadertoyPassSpec(
          language: ShadertoyLanguage.wgslSnippet, source: wgsl),
    );

const _selfFeedbackChannels = [
  ShadertoyChannel.buffer(ShadertoyChannelKind.bufferA),
  ShadertoyChannel.none(),
  ShadertoyChannel.none(),
  ShadertoyChannel.none(),
];

ShadertoyEngine _feedback({required String buffer, required String image}) =>
    ShadertoyEngine(
      buffers: [
        ShadertoyPassSpec(
            language: ShadertoyLanguage.wgslSnippet,
            source: buffer,
            channels: _selfFeedbackChannels),
      ],
      image: ShadertoyPassSpec(
          language: ShadertoyLanguage.wgslSnippet,
          source: image,
          channels: _selfFeedbackChannels),
    );

// ═════════════════════════════ UI polish ════════════════════════════════

const _meshGradient = '''
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  var col = vec3f(0.06, 0.05, 0.12);
  // Four drifting color blobs blended like a mesh gradient.
  let blobs = array<vec4f, 4>(
    vec4f(0.90, 0.30, 0.55, 0.0),
    vec4f(0.25, 0.55, 0.95, 2.1),
    vec4f(0.98, 0.65, 0.25, 4.2),
    vec4f(0.45, 0.90, 0.70, 5.3));
  for (var i = 0; i < 4; i++) {
    let b = blobs[i];
    let c = vec2f(0.5 + 0.38 * sin(iTime * 0.35 + b.w),
                  0.5 + 0.38 * cos(iTime * 0.27 + b.w * 1.7));
    let d = distance(uv, c);
    col += b.rgb * exp(-d * d * 7.0) * 0.55;
  }
  return vec4f(pow(col, vec3f(0.9)), 1.0);
}''';

const _holoCard = '''
fn sdRoundRect(p: vec2f, b: vec2f, r: f32) -> f32 {
  let q = abs(p) - b + vec2f(r);
  return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
  let m = (iMouse.xy - 0.5 * iResolution.xy) / iResolution.y;
  let d = sdRoundRect(uv, vec2f(0.62, 0.36), 0.06);
  if (d > 0.0) {
    return vec4f(vec3f(0.05) * (1.0 - smoothstep(0.0, 0.02, d) * 0.5), 1.0);
  }
  // Holographic foil: interference bands steered by the pointer.
  let tilt = dot(normalize(uv - m + vec2f(0.001)), vec2f(0.7, 0.7));
  let band = sin((uv.x * 4.0 + uv.y * 7.0 + tilt * 5.0 + iTime * 0.6) * 6.2831);
  let hue = 0.6 + 0.4 * sin(vec3f(0.0, 2.1, 4.2) + band * 2.0 + tilt * 6.0);
  let sheen = exp(-abs(band) * 1.6) * (0.35 + 0.4 * exp(-length(uv - m) * 2.5));
  let base = mix(vec3f(0.10, 0.11, 0.16), vec3f(0.16, 0.18, 0.26), uv.y + 0.5);
  return vec4f(base + hue * sheen, 1.0);
}''';

const _shimmer = '''
fn box(uv: vec2f, c: vec2f, b: vec2f) -> f32 {
  let q = abs(uv - c) - b;
  return step(max(q.x, q.y), 0.0);
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  // Skeleton placeholder card: avatar circle + three text rows.
  var mask = step(distance(uv, vec2f(0.14, 0.70)), 0.075);
  mask = max(mask, box(uv, vec2f(0.55, 0.74), vec2f(0.28, 0.030)));
  mask = max(mask, box(uv, vec2f(0.50, 0.62), vec2f(0.33, 0.030)));
  mask = max(mask, box(uv, vec2f(0.42, 0.50), vec2f(0.25, 0.030)));
  mask = max(mask, box(uv, vec2f(0.50, 0.28), vec2f(0.40, 0.085)));
  // Sweeping diagonal shimmer highlight.
  let sweep = fract(iTime * 0.45);
  let x = uv.x + uv.y * 0.35;
  let hi = exp(-pow((x - sweep * 1.6 + 0.15) * 9.0, 2.0));
  let base = vec3f(0.15, 0.16, 0.20) + vec3f(0.03, 0.04, 0.07) * uv.y;
  let bg = vec3f(0.06, 0.07, 0.10) + vec3f(0.02, 0.02, 0.04) * (1.0 - uv.y);
  let col = mix(base, base + vec3f(0.10, 0.10, 0.12), hi) * mask
      + bg * (1.0 - mask);
  return vec4f(col, 1.0);
}''';

const _neonBorder = '''
fn sdRoundRect(p: vec2f, b: vec2f, r: f32) -> f32 {
  let q = abs(p) - b + vec2f(r);
  return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
  let d = abs(sdRoundRect(uv, vec2f(0.58, 0.32), 0.10));
  // Hue travels around the border.
  let angle = atan2(uv.y, uv.x) / 6.2831 + iTime * 0.15;
  let hue = 0.5 + 0.5 * sin(vec3f(0.0, 2.1, 4.2) + angle * 6.2831);
  let glow = 0.012 / (d + 0.010) + 0.25 * exp(-d * 26.0);
  return vec4f(vec3f(0.03, 0.03, 0.05) + hue * glow, 1.0);
}''';

const _rippleTransition = '''
fn sceneA(uv: vec2f) -> vec3f {
  return mix(vec3f(0.95, 0.45, 0.30), vec3f(0.98, 0.75, 0.35), uv.y);
}
fn sceneB(uv: vec2f) -> vec3f {
  let g = step(0.5, fract(uv.x * 6.0)) * step(0.5, fract(uv.y * 6.0));
  return mix(vec3f(0.12, 0.25, 0.55), vec3f(0.20, 0.60, 0.85), uv.y) + g * 0.08;
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  // Auto-cycling reveal; a tap re-centers the ripple origin (iMouse).
  let origin = select(vec2f(0.5), iMouse.xy / iResolution.xy,
                      iMouse.x + iMouse.y > 0.0);
  let progress = fract(iTime * 0.30);
  let radius = progress * 1.6;
  let d = distance(uv, origin);
  let edge = smoothstep(radius, radius - 0.09, d);
  // Refraction-style distortion right at the moving edge.
  let ring = exp(-pow((d - radius) * 18.0, 2.0));
  let dir = normalize(uv - origin + vec2f(0.0001));
  let warped = uv - dir * ring * 0.03;
  let col = mix(sceneA(warped), sceneB(warped), edge) + vec3f(ring * 0.18);
  return vec4f(col, 1.0);
}''';

// ═══════════════════════════ Media & imaging ════════════════════════════

// A procedural "photo" all the filter showcases share.
const _sourceImage = '''
fn sourceImage(uv: vec2f) -> vec3f {
  let sky = mix(vec3f(0.95, 0.55, 0.30), vec3f(0.25, 0.30, 0.60),
                smoothstep(0.35, 0.9, uv.y));
  let sun = exp(-distance(uv, vec2f(0.62, 0.42)) * 9.0);
  let hills = smoothstep(0.34 + 0.08 * sin(uv.x * 9.0) * sin(uv.x * 3.7),
                         0.30, uv.y);
  let ground = mix(vec3f(0.10, 0.16, 0.12), vec3f(0.05, 0.09, 0.08), uv.y * 2.0);
  var col = sky + vec3f(1.0, 0.8, 0.5) * sun;
  col = mix(col, ground, hills);
  return col;
}''';

const _halftone = '''
$_sourceImage
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let col = sourceImage(uv);
  let lum = dot(col, vec3f(0.299, 0.587, 0.114));
  // Rotated halftone grid; dot radius follows brightness.
  let ang = 0.6 + 0.1 * sin(iTime * 0.3);
  let rot = mat2x2f(cos(ang), -sin(ang), sin(ang), cos(ang));
  let cell = 90.0;
  let g = rot * (fragCoord / iResolution.y) * cell;
  let d = distance(fract(g), vec2f(0.5));
  let dot_ = smoothstep(sqrt(lum) * 0.62, sqrt(lum) * 0.62 - 0.08, d);
  let ink = mix(vec3f(0.93, 0.90, 0.84), col * 0.9, dot_);
  return vec4f(ink, 1.0);
}''';

const _kuwahara = '''
$_sourceImage
fn regionStats(uv: vec2f, o: vec2f, r: f32) -> vec4f {
  var mean = vec3f(0.0);
  var m2 = 0.0;
  for (var y = 0; y < 3; y++) {
    for (var x = 0; x < 3; x++) {
      let s = sourceImage(uv + o + vec2f(f32(x), f32(y)) * r);
      mean += s;
      m2 += dot(s, s);
    }
  }
  mean /= 9.0;
  let variance = m2 / 9.0 - dot(mean, mean);
  return vec4f(mean, variance);
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let r = 0.008;
  // Kuwahara: keep the mean of the least-varying quadrant → oil paint.
  var best = regionStats(uv, vec2f(-2.0, -2.0) * r, r);
  let q1 = regionStats(uv, vec2f(0.0, -2.0) * r, r);
  let q2 = regionStats(uv, vec2f(-2.0, 0.0) * r, r);
  let q3 = regionStats(uv, vec2f(0.0, 0.0) * r, r);
  if (q1.w < best.w) { best = q1; }
  if (q2.w < best.w) { best = q2; }
  if (q3.w < best.w) { best = q3; }
  return vec4f(best.rgb, 1.0);
}''';

const _chromaGrain = '''
$_sourceImage
fn hash(p: vec2f) -> f32 {
  return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let c = uv - 0.5;
  // Lens-style chromatic aberration grows toward the edges.
  let k = (0.006 + 0.004 * sin(iTime * 0.7)) * dot(c, c) * 8.0;
  let col = vec3f(
      sourceImage(uv + c * k).r,
      sourceImage(uv).g,
      sourceImage(uv - c * k).b);
  let grain = (hash(fragCoord + fract(iTime) * 100.0) - 0.5) * 0.07;
  let vignette = 1.0 - dot(c, c) * 0.9;
  return vec4f((col + grain) * vignette, 1.0);
}''';

const _bloomBufferA = '''
$_sourceImage
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  // Animated bright orbs over the scene; BufferA holds the raw HDR-ish pass.
  var col = sourceImage(uv) * 0.6;
  for (var i = 0; i < 3; i++) {
    let f = f32(i);
    let p = vec2f(0.5 + 0.33 * sin(iTime * 0.8 + f * 2.1),
                  0.5 + 0.28 * cos(iTime * 0.6 + f * 1.7));
    col += vec3f(1.2, 0.9, 0.5) * exp(-distance(uv, p) * 22.0) * 2.0;
  }
  return vec4f(col, 1.0);
}''';

const _bloomImage = '''
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let base = textureSampleLevel(iChannel0, stSampler, uv, 0.0).rgb;
  // Cheap 13-tap blur of the bright parts = the bloom halo.
  var glow = vec3f(0.0);
  let px = 3.5 / iResolution.xy;
  for (var y = -2; y <= 2; y++) {
    for (var x = -2; x <= 2; x++) {
      if ((x + y) % 2 == 0) {
        let s = textureSampleLevel(iChannel0, stSampler,
            uv + vec2f(f32(x), f32(y)) * px, 0.0).rgb;
        glow += max(s - vec3f(0.7), vec3f(0.0));
      }
    }
  }
  glow /= 13.0;
  let col = base + glow * 1.6;
  // Filmic-ish tonemap.
  return vec4f(col / (col + vec3f(0.45)), 1.0);
}''';

// ═══════════════════════ Simulation & generative ════════════════════════

const _reactionDiffusionBuffer = '''
fn mainImage(fragCoord: vec2f) -> vec4f {
  let px = 1.0 / iResolution.xy;
  let uv = fragCoord * px;
  // Gray-Scott reaction-diffusion; chemicals in rg of the feedback buffer.
  if (iFrame < 2.0) {
    let seed = step(distance(uv, vec2f(0.5)), 0.05)
             + step(distance(uv, vec2f(0.3, 0.6)), 0.03);
    return vec4f(1.0, seed, 0.0, 1.0);
  }
  var lap = vec2f(0.0);
  var c = vec2f(0.0);
  for (var y = -1; y <= 1; y++) {
    for (var x = -1; x <= 1; x++) {
      let s = textureSampleLevel(iChannel0, stSampler,
          uv + vec2f(f32(x), f32(y)) * px, 0.0).rg;
      let w = select(select(0.05, 0.2, x == 0 || y == 0), -1.0,
                     x == 0 && y == 0);
      lap += s * w;
      if (x == 0 && y == 0) { c = s; }
    }
  }
  let f = 0.037;
  let k = 0.06;
  let abb = c.x * c.y * c.y;
  var a = c.x + (1.0 * lap.x - abb + f * (1.0 - c.x)) * 1.0;
  var b = c.y + (0.5 * lap.y + abb - (k + f) * c.y) * 1.0;
  // Pointer injects chemical B.
  if (iMouse.x + iMouse.y > 0.0) {
    b += exp(-distance(fragCoord, iMouse.xy) * 0.15) * 0.15;
  }
  return vec4f(clamp(a, 0.0, 1.0), clamp(b, 0.0, 1.0), 0.0, 1.0);
}''';

const _reactionDiffusionImage = '''
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let c = textureSampleLevel(iChannel0, stSampler, uv, 0.0).rg;
  let v = smoothstep(0.15, 0.45, c.y);
  let col = mix(vec3f(0.04, 0.06, 0.12),
                mix(vec3f(0.10, 0.55, 0.65), vec3f(0.95, 0.90, 0.75), v), v);
  return vec4f(col, 1.0);
}''';

const _gameOfLifeBuffer = '''
fn hash(p: vec2f) -> f32 {
  return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}
fn cell(uv: vec2f, cellPx: vec2f) -> f32 {
  // Snap to the center of the automaton's cell so linear filtering can't
  // blend neighboring cells.
  let t = (floor(uv / cellPx) + 0.5) * cellPx;
  return step(0.5, textureSampleLevel(iChannel0, stSampler, t, 0.0).r);
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let px = 1.0 / iResolution.xy;
  let uv = fragCoord * px;
  let cellPx = px * 3.0; // one automaton cell = 3x3 texels
  if (iFrame < 2.0) {
    return vec4f(step(0.72, hash(floor(fragCoord / 3.0))), 0.0, 0.0, 1.0);
  }
  var n = 0.0;
  for (var y = -1; y <= 1; y++) {
    for (var x = -1; x <= 1; x++) {
      if (x != 0 || y != 0) {
        n += cell(uv + vec2f(f32(x), f32(y)) * cellPx, cellPx);
      }
    }
  }
  let alive = cell(uv, cellPx);
  var next = 0.0;
  if (alive > 0.5 && (n == 2.0 || n == 3.0)) { next = 1.0; }
  if (alive < 0.5 && n == 3.0) { next = 1.0; }
  // Pointer sprinkles new life.
  if (iMouse.x + iMouse.y > 0.0
      && distance(fragCoord, iMouse.xy) < 8.0
      && hash(fragCoord + iTime) > 0.5) { next = 1.0; }
  // g channel: decaying trail of recently-alive cells.
  let t = (floor(uv / cellPx) + 0.5) * cellPx;
  let trail = textureSampleLevel(iChannel0, stSampler, t, 0.0).g;
  return vec4f(next, max(next, trail * 0.90), 0.0, 1.0);
}''';

const _gameOfLifeImage = '''
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let c = textureSampleLevel(iChannel0, stSampler, uv, 0.0);
  // Live cells bright green; recently-dead fade through teal to blue.
  let trail = mix(vec3f(0.05, 0.07, 0.10),
                  mix(vec3f(0.10, 0.25, 0.45), vec3f(0.15, 0.60, 0.55), c.g),
                  smoothstep(0.02, 0.6, c.g));
  let col = mix(trail, vec3f(0.60, 0.98, 0.65), c.r);
  return vec4f(col, 1.0);
}''';

const _inkFlowBuffer = '''
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
fn mainImage(fragCoord: vec2f) -> vec4f {
  let px = 1.0 / iResolution.xy;
  let uv = fragCoord * px;
  // Curl-noise flow field advects the ink stored in the feedback buffer.
  let e = 0.01;
  let p = uv * 3.0 + vec2f(0.0, iTime * 0.05);
  let curl = vec2f(noise(p + vec2f(0.0, e)) - noise(p - vec2f(0.0, e)),
                   noise(p - vec2f(e, 0.0)) - noise(p + vec2f(e, 0.0))) / e;
  let src = uv - curl * px * 22.0;
  var ink = textureSampleLevel(iChannel0, stSampler, src, 0.0).rgb * 0.994;
  // Pointer (or an idle emitter) injects colored ink.
  var emit = vec2f(0.5 + 0.25 * sin(iTime * 0.9), 0.5 + 0.25 * cos(iTime * 0.7));
  if (iMouse.x + iMouse.y > 0.0) { emit = iMouse.xy * px; }
  let d = distance(uv, emit);
  let hue = 0.5 + 0.5 * sin(vec3f(0.0, 2.1, 4.2) + iTime * 0.8);
  ink += hue * exp(-d * d * 900.0) * 0.9;
  return vec4f(min(ink, vec3f(1.4)), 1.0);
}''';

const _inkFlowImage = '''
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let ink = textureSampleLevel(iChannel0, stSampler, uv, 0.0).rgb;
  return vec4f(vec3f(0.03, 0.04, 0.07) + ink, 1.0);
}''';

const _boidsKernel = '''
struct Particle { pos: vec2f, vel: vec2f };
struct SimParams { dt: f32, time: f32, count: f32, size: f32 };
@group(0) @binding(0) var<uniform> params: SimParams;
@group(0) @binding(1) var<storage, read_write> particles: array<Particle>;

@compute @workgroup_size(64)
fn simulate(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  let n = u32(params.count);
  if (i >= n) { return; }
  var p = particles[i];
  var sep = vec2f(0.0);
  var ali = vec2f(0.0);
  var coh = vec2f(0.0);
  var near = 0.0;
  for (var j = 0u; j < n; j++) {
    if (j == i) { continue; }
    let q = particles[j];
    let d = q.pos - p.pos;
    let dist = length(d) + 1e-5;
    if (dist < 0.16) {
      near += 1.0;
      ali += q.vel;
      coh += q.pos;
      if (dist < 0.05) { sep -= d / (dist * dist) * 0.002; }
    }
  }
  if (near > 0.0) {
    ali = (ali / near - p.vel) * 0.9;
    coh = (coh / near - p.pos) * 1.4;
  }
  var acc = sep + ali * params.dt * 8.0 + coh * params.dt * 8.0;
  acc += -p.pos * 0.12 * params.dt;      // soft pull to center
  p.vel += acc;
  let speed = length(p.vel) + 1e-5;
  p.vel = p.vel / speed * clamp(speed, 0.18, 0.55);
  p.pos += p.vel * params.dt;
  if (abs(p.pos.x) > 1.0) { p.vel.x = -p.vel.x; p.pos.x = clamp(p.pos.x, -1.0, 1.0); }
  if (abs(p.pos.y) > 1.0) { p.vel.y = -p.vel.y; p.pos.y = clamp(p.pos.y, -1.0, 1.0); }
  particles[i] = p;
}''';

const _fireworksKernel = '''
struct Particle { pos: vec2f, vel: vec2f };
struct SimParams { dt: f32, time: f32, count: f32, size: f32 };
@group(0) @binding(0) var<uniform> params: SimParams;
@group(0) @binding(1) var<storage, read_write> particles: array<Particle>;

fn hash1(x: f32) -> f32 { return fract(sin(x * 127.1) * 43758.5453); }

@compute @workgroup_size(64)
fn simulate(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i >= u32(params.count)) { return; }
  var p = particles[i];
  p.vel.y -= 0.55 * params.dt;           // gravity
  p.vel *= (1.0 - 0.35 * params.dt);     // drag
  p.pos += p.vel * params.dt;
  // Fallen particles relaunch in the next burst: each ~1.6 s window has a
  // deterministic burst center; per-particle angle from its index.
  if (p.pos.y < -1.05) {
    let burst = floor(params.time / 1.6);
    let cx = hash1(burst * 7.3) * 1.2 - 0.6;
    let cy = hash1(burst * 3.1) * 0.5 + 0.1;
    let ang = hash1(f32(i) * 1.7 + burst) * 6.2831;
    let spd = 0.35 + 0.45 * hash1(f32(i) * 9.2 + burst * 2.0);
    p.pos = vec2f(cx, cy);
    p.vel = vec2f(cos(ang), sin(ang)) * spd;
  }
  particles[i] = p;
}''';

// ═══════════════════════════ Scenes & games ═════════════════════════════

const _light2d = '''
fn sdBox(p: vec2f, c: vec2f, b: vec2f) -> f32 {
  let q = abs(p - c) - b;
  return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0);
}
fn sceneDist(p: vec2f) -> f32 {
  var d = sdBox(p, vec2f(-0.45, 0.15), vec2f(0.13, 0.13));
  d = min(d, sdBox(p, vec2f(0.35, -0.05), vec2f(0.10, 0.26)));
  d = min(d, sdBox(p, vec2f(0.0, -0.42), vec2f(0.30, 0.07)));
  d = min(d, distance(p, vec2f(-0.15, 0.42)) - 0.10);
  return d;
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
  var light = (iMouse.xy - 0.5 * iResolution.xy) / iResolution.y;
  if (iMouse.x + iMouse.y <= 0.0) {
    light = vec2f(0.55 * sin(iTime * 0.7), 0.4 * cos(iTime * 0.5));
  }
  // Soft 2D shadows: march from the pixel toward the light through the SDF.
  var vis = 1.0;
  let toL = light - uv;
  let lenL = length(toL);
  let dirL = toL / max(lenL, 1e-4);
  var t = 0.012;
  for (var s = 0; s < 40; s++) {
    if (t >= lenL) { break; }
    let d = sceneDist(uv + dirL * t);
    vis = min(vis, clamp(10.0 * d / t, 0.0, 1.0));
    t += max(d, 0.008);
  }
  let inShape = step(sceneDist(uv), 0.0);
  let falloff = 1.0 / (1.0 + lenL * lenL * 7.0);
  let warm = vec3f(1.00, 0.85, 0.60) * vis * falloff * 1.6;
  let base = vec3f(0.05, 0.06, 0.09) + warm;
  let shape = vec3f(0.16, 0.18, 0.24) + vec3f(0.30, 0.25, 0.18) * vis * falloff;
  let glow = exp(-lenL * 14.0) * vec3f(1.0, 0.9, 0.7);
  return vec4f(mix(base, shape, inShape) + glow, 1.0);
}''';

const _fogOfWarBuffer = '''
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let prev = textureSampleLevel(iChannel0, stSampler, uv, 0.0).r;
  // The explorer reveals around itself; explored terrain stays revealed.
  var hero = vec2f(0.5 + 0.35 * sin(iTime * 0.5),
                   0.5 + 0.30 * sin(iTime * 0.83 + 1.7));
  if (iMouse.x + iMouse.y > 0.0) { hero = iMouse.xy / iResolution.xy; }
  let d = distance((uv - hero) * vec2f(iResolution.x / iResolution.y, 1.0),
                   vec2f(0.0));
  let reveal = smoothstep(0.16, 0.05, d);
  return vec4f(max(prev * 0.999, reveal), 0.0, 0.0, 1.0);
}''';

const _fogOfWarImage = '''
fn hash(p: vec2f) -> f32 {
  return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  // Procedural terrain tiles.
  let cell = floor(uv * 12.0);
  let h = hash(cell);
  var terrain = mix(vec3f(0.16, 0.30, 0.16), vec3f(0.24, 0.40, 0.20),
                    step(0.5, h));
  if (h > 0.82) { terrain = vec3f(0.22, 0.30, 0.42); }   // lakes
  if (h < 0.12) { terrain = vec3f(0.35, 0.33, 0.28); }   // mountains
  let grid = step(0.94, fract(uv.x * 12.0)) + step(0.94, fract(uv.y * 12.0));
  terrain -= grid * 0.02;
  let fog = textureSampleLevel(iChannel0, stSampler, uv, 0.0).r;
  let dim = mix(vec3f(0.03, 0.04, 0.06), terrain, 0.15 + 0.85 * fog);
  return vec4f(dim, 1.0);
}''';


const _breakoutBuffer = '''
// GPU-resident game state, Shadertoy-style: data texels in the buffer's
// bottom row hold the ball and the brick grid; every fragment recomputes
// its own cell from the previous frame.
//   cell 0: ball position   cell 1: ball velocity   cells 4..35: bricks 8x4
fn data(i: i32) -> vec4f {
  // State cells live at shadertoy-space y < 1 — after the engine's y-flip
  // that is the LAST texture row, so sample there.
  let px = 1.0 / iResolution.xy;
  return textureSampleLevel(iChannel0, stSampler,
      vec2f((f32(i) + 0.5) * px.x, 1.0 - 0.5 * px.y), 0.0);
}
fn paddleX() -> f32 {
  if (iMouse.x + iMouse.y > 0.0) { return iMouse.x / iResolution.x; }
  return 0.5 + 0.35 * sin(iTime * 0.9);
}
fn brickIndex(p: vec2f) -> i32 {
  if (p.y < 0.60 || p.y > 0.92 || p.x < 0.02 || p.x > 0.98) { return -1; }
  let cx = i32((p.x - 0.02) / 0.12);
  let cy = i32((p.y - 0.60) / 0.08);
  return 4 + cy * 8 + min(cx, 7);
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let cell = i32(fragCoord.x);
  if (fragCoord.y >= 1.0 || cell > 35) { return vec4f(0.0); }
  let dt = clamp(iTimeDelta, 0.001, 0.033);
  if (iFrame < 2.0) {
    if (cell == 0) { return vec4f(0.5, 0.30, 0.0, 1.0); }
    if (cell == 1) { return vec4f(0.34, 0.52, 0.0, 1.0); }
    return vec4f(1.0, 0.0, 0.0, 1.0); // bricks alive
  }
  var pos = data(0).xy;
  var vel = data(1).xy;
  let hitBrick = brickIndex(pos + vel * dt);
  // Brick cells: die when the ball enters them.
  if (cell >= 4) {
    var alive = data(cell).x;
    if (cell == hitBrick && alive > 0.5) { alive = 0.0; }
    // All bricks cleared? Reset the wall for an endless demo.
    var remaining = 0.0;
    for (var i = 4; i <= 35; i++) { remaining += data(i).x; }
    if (remaining < 0.5) { alive = 1.0; }
    return vec4f(alive, 0.0, 0.0, 1.0);
  }
  // Ball physics (cells 0 and 1 compute the same step).
  var next = pos + vel * dt;
  if (next.x < 0.015 || next.x > 0.985) { vel.x = -vel.x; }
  if (next.y > 0.985) { vel.y = -abs(vel.y); }
  if (hitBrick >= 0 && data(hitBrick).x > 0.5) { vel.y = -vel.y; }
  // Paddle bounce with english from the hit offset.
  let px_ = paddleX();
  if (next.y < 0.085 && next.y > 0.045 && vel.y < 0.0
      && abs(next.x - px_) < 0.10) {
    vel.y = abs(vel.y);
    vel.x = clamp(vel.x + (next.x - px_) * 2.2, -0.75, 0.75);
  }
  // Missed: respawn.
  if (next.y < 0.0) {
    if (cell == 0) { return vec4f(0.5, 0.30, 0.0, 1.0); }
    return vec4f(0.34, 0.52, 0.0, 1.0);
  }
  next = pos + vel * dt;
  if (cell == 0) { return vec4f(clamp(next, vec2f(0.0), vec2f(1.0)), 0.0, 1.0); }
  return vec4f(vel, 0.0, 1.0);
}''';

const _breakoutImage = '''
fn data(i: i32) -> vec4f {
  // State cells live at shadertoy-space y < 1 — after the engine's y-flip
  // that is the LAST texture row, so sample there.
  let px = 1.0 / iResolution.xy;
  return textureSampleLevel(iChannel0, stSampler,
      vec2f((f32(i) + 0.5) * px.x, 1.0 - 0.5 * px.y), 0.0);
}
fn paddleX() -> f32 {
  if (iMouse.x + iMouse.y > 0.0) { return iMouse.x / iResolution.x; }
  return 0.5 + 0.35 * sin(iTime * 0.9);
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let aspect = iResolution.x / iResolution.y;
  var col = mix(vec3f(0.04, 0.05, 0.10), vec3f(0.08, 0.07, 0.16), uv.y);
  // Bricks.
  if (uv.y >= 0.60 && uv.y <= 0.92 && uv.x >= 0.02 && uv.x <= 0.98) {
    let cx = i32((uv.x - 0.02) / 0.12);
    let cy = i32((uv.y - 0.60) / 0.08);
    let alive = data(4 + cy * 8 + min(cx, 7)).x;
    if (alive > 0.5) {
      let inX = fract((uv.x - 0.02) / 0.12);
      let inY = fract((uv.y - 0.60) / 0.08);
      let border = step(0.06, inX) * step(inX, 0.94)
                 * step(0.10, inY) * step(inY, 0.90);
      let hue = 0.5 + 0.5 * sin(vec3f(0.0, 2.1, 4.2) + f32(cy) * 1.1);
      col = mix(col, hue * (0.55 + 0.25 * inY), border);
    }
  }
  // Paddle.
  let pxd = paddleX();
  if (uv.y > 0.055 && uv.y < 0.075 && abs(uv.x - pxd) < 0.10) {
    col = vec3f(0.85, 0.90, 1.00);
  }
  // Ball with a soft glow.
  let ball = data(0).xy;
  let d = length((uv - ball) * vec2f(aspect, 1.0));
  col += vec3f(1.0, 0.85, 0.55) * exp(-d * d * 2200.0);
  col += vec3f(1.0, 0.7, 0.4) * exp(-d * 9.0) * 0.12;
  return vec4f(col, 1.0);
}''';


const _racerBuffer = '''
// State cells — the whole game lives in two data texels:
//   cell 0: (playerX, speed, distance, crashFlash)
//   cell 1: (alive, score, bestScore, prevThrottleKey)
fn data(i: i32) -> vec4f {
  let px = 1.0 / iResolution.xy;
  return textureSampleLevel(iChannel0, stSampler,
      vec2f((f32(i) + 0.5) * px.x, 1.0 - 0.5 * px.y), 0.0);
}
fn hash1(x: f32) -> f32 { return fract(sin(x * 127.1) * 43758.5453); }
fn obstacleLane(seg: f32) -> f32 {
  // Obstacle-free starting corridor, then rivals on ~45% of segments.
  if (seg < 40.0 || hash1(seg * 3.7) < 0.55) { return -2.0; }
  return (floor(hash1(seg * 7.1) * 3.0) - 1.0) * 0.55;
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  if (fragCoord.y >= 1.0 || fragCoord.x >= 2.0) { return vec4f(0.0); }
  let cell = i32(fragCoord.x);
  let dt = clamp(iTimeDelta, 0.001, 0.033);
  if (iFrame < 2.0) {
    if (cell == 0) { return vec4f(0.0, 0.3, 0.0, 0.0); }
    return vec4f(1.0, 0.0, 0.0, 0.0);
  }
  let s0 = data(0);
  let s1 = data(1);
  let alive = s1.x;
  let up = iKeys.z;
  // Restart needs a FRESH throttle press after death (edge, not level).
  let restart = (alive < 0.5) && (up > 0.5) && (s1.w < 0.5);
  if (restart) {
    if (cell == 0) { return vec4f(0.0, 0.3, 0.0, 0.0); }
    return vec4f(1.0, 0.0, s1.z, up);
  }
  if (alive < 0.5) {
    // Dead: everything freezes except the crash flash and the key latch.
    if (cell == 0) { return vec4f(s0.x, 0.0, s0.z, s0.w * exp(-dt * 3.0)); }
    return vec4f(0.0, s1.y, s1.z, up);
  }
  var playerX = s0.x;
  var speed = s0.y;
  let dist = s0.z;
  var crash = s0.w * exp(-dt * 3.0);
  playerX += (iKeys.y - iKeys.x) * dt * (0.9 + speed);
  playerX -= sin(dist * 0.05) * speed * dt * 0.55;
  // Steering assist: with no left/right input the car pulls back toward
  // the road, fighting the centrifugal drift (throttle-only is drivable —
  // and swings across all three lanes instead of parking on the rail).
  if (iKeys.x + iKeys.y < 0.5) {
    playerX += (0.0 - playerX) * dt * 1.2;
  }
  playerX = clamp(playerX, -1.15, 1.15);
  let offroad = step(0.95, abs(playerX));
  speed += up * (1.0 - speed) * dt * 0.9;
  speed -= iKeys.w * dt * 1.4;
  if (iKeys.x + iKeys.y + iKeys.z + iKeys.w < 0.5) {
    speed += (0.45 - speed) * dt * 0.5;
  }
  speed -= speed * dt * (0.12 + offroad * 1.8);
  speed = clamp(speed, 0.0, 1.0);
  let newDist = dist + speed * dt * 9.0;
  // A rival reaches the player's bumper 3 segments after it appears on
  // screen — crossing that segment in its lane is fatal.
  var died = false;
  if (floor(newDist) > floor(dist)) {
    let lane = obstacleLane(floor(newDist) + 3.0);
    if (lane > -1.5 && abs(playerX - lane) < 0.28) { died = true; }
  }
  if (cell == 0) {
    if (died) { return vec4f(playerX, 0.0, newDist, 1.0); }
    return vec4f(playerX, speed, newDist, crash);
  }
  // Cell 1: endless score ticks with speed; best survives death.
  var score = s1.y + speed * dt * 30.0;
  if (died) {
    return vec4f(0.0, score, max(s1.z, score), up);
  }
  return vec4f(1.0, score, s1.z, up);
}''';

const _racerImage = '''
fn data(i: i32) -> vec4f {
  let px = 1.0 / iResolution.xy;
  return textureSampleLevel(iChannel0, stSampler,
      vec2f((f32(i) + 0.5) * px.x, 1.0 - 0.5 * px.y), 0.0);
}
fn hash1(x: f32) -> f32 { return fract(sin(x * 127.1) * 43758.5453); }
fn obstacleLane(seg: f32) -> f32 {
  if (seg < 40.0 || hash1(seg * 3.7) < 0.55) { return -2.0; }
  return (floor(hash1(seg * 7.1) * 3.0) - 1.0) * 0.55;
}
fn roadCenter(playerX: f32, dist: f32, z: f32, p: f32) -> f32 {
  return 0.5 - playerX * 0.10 * p
       + sin((dist + z * 3.0) * 0.05) * (1.0 - p) * (1.0 - p) * 0.45;
}
fn segBox(p: vec2f, c: vec2f, b: vec2f) -> f32 {
  let q = abs(p - c) - b;
  return step(max(q.x, q.y), 0.0);
}
// Seven-segment digit in a unit box (y up).
fn digitPix(p: vec2f, d: i32) -> f32 {
  var masks = array<i32, 10>(0x3F, 0x06, 0x5B, 0x4F, 0x66,
                             0x6D, 0x7D, 0x07, 0x7F, 0x6F);
  let m = masks[clamp(d, 0, 9)];
  var v = 0.0;
  if ((m & 1) != 0) { v = max(v, segBox(p, vec2f(0.5, 0.93), vec2f(0.30, 0.07))); }
  if ((m & 2) != 0) { v = max(v, segBox(p, vec2f(0.82, 0.72), vec2f(0.07, 0.19))); }
  if ((m & 4) != 0) { v = max(v, segBox(p, vec2f(0.82, 0.28), vec2f(0.07, 0.19))); }
  if ((m & 8) != 0) { v = max(v, segBox(p, vec2f(0.5, 0.07), vec2f(0.30, 0.07))); }
  if ((m & 16) != 0) { v = max(v, segBox(p, vec2f(0.18, 0.28), vec2f(0.07, 0.19))); }
  if ((m & 32) != 0) { v = max(v, segBox(p, vec2f(0.18, 0.72), vec2f(0.07, 0.19))); }
  if ((m & 64) != 0) { v = max(v, segBox(p, vec2f(0.5, 0.5), vec2f(0.30, 0.07))); }
  return v;
}
fn drawNumber(uv: vec2f, org: vec2f, scale: vec2f, value: f32,
              ndigits: i32) -> f32 {
  var v = 0.0;
  var val = i32(value);
  for (var i = 0; i < ndigits; i++) {
    let slot = ndigits - 1 - i;
    let cell = vec2f(org.x + f32(slot) * scale.x * 1.25, org.y);
    let p = (uv - cell) / scale;
    if (p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0) {
      v = max(v, digitPix(p, val % 10));
    }
    val = val / 10;
  }
  return v;
}
// 5x7 bitmap glyphs for "GAME OVER" (row 0 = top, 5-bit rows, MSB left).
fn glyphRow(g: i32, row: i32) -> i32 {
  var font = array<i32, 56>(
    0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E,  // G
    0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11,  // A
    0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11,  // M
    0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F,  // E
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // space
    0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E,  // O
    0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04,  // V
    0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11); // R
  return font[g * 7 + row];
}
fn gameOverText(uv: vec2f, org: vec2f, scale: vec2f) -> f32 {
  var order = array<i32, 9>(0, 1, 2, 3, 4, 5, 6, 3, 7); // G A M E _ O V E R
  for (var i = 0; i < 9; i++) {
    let cell = vec2f(org.x + f32(i) * scale.x * 6.0, org.y);
    let p = (uv - cell) / scale;
    if (p.x >= 0.0 && p.x < 5.0 && p.y >= 0.0 && p.y < 7.0) {
      let row = 6 - i32(p.y);
      let col = i32(p.x);
      if (((glyphRow(order[i], row) >> u32(4 - col)) & 1) != 0) {
        return 1.0;
      }
    }
  }
  return 0.0;
}
fn mainImage(fragCoord: vec2f) -> vec4f {
  let uv = fragCoord / iResolution.xy;
  let s0 = data(0);
  let s1 = data(1);
  let playerX = s0.x;
  let speed = s0.y;
  let dist = s0.z;
  let crash = s0.w;
  let alive = s1.x;
  let horizon = 0.56;
  var col: vec3f;
  if (uv.y > horizon) {
    col = mix(vec3f(0.98, 0.62, 0.35), vec3f(0.20, 0.25, 0.55),
              (uv.y - horizon) / (1.0 - horizon));
    col += vec3f(1.0, 0.8, 0.4)
        * exp(-distance(uv, vec2f(0.5 - sin(dist * 0.05) * 0.2, horizon + 0.10)) * 9.0);
    let ridge = horizon + 0.035
        + 0.03 * sin(uv.x * 11.0 + sin(dist * 0.05) * 2.0);
    if (uv.y < ridge) { col = vec3f(0.16, 0.12, 0.24); }
  } else {
    let p = (horizon - uv.y) / horizon;
    let z = 1.0 / max(p, 0.02);
    let seg = dist + z * 3.0;
    let center = roadCenter(playerX, dist, z, p);
    let halfW = p * 0.42 + 0.01;
    let xr = (uv.x - center) / halfW;
    let stripe = step(0.5, fract(seg * 0.7));
    col = mix(vec3f(0.10, 0.35, 0.12), vec3f(0.08, 0.28, 0.10), stripe);
    if (abs(xr) < 1.08 && abs(xr) >= 1.0) {
      col = mix(vec3f(0.85, 0.15, 0.12), vec3f(0.92, 0.90, 0.88), stripe);
    }
    if (abs(xr) < 1.0) {
      col = mix(vec3f(0.22, 0.22, 0.25), vec3f(0.25, 0.25, 0.28), stripe);
      if (abs(xr) < 0.035 && fract(seg * 0.7) > 0.5) {
        col = vec3f(0.92, 0.92, 0.85);
      }
      if (abs(abs(xr) - 0.55) < 0.02) { col *= 1.25; }
    }
    col = mix(vec3f(0.65, 0.55, 0.60), col, clamp(p * 2.2, 0.0, 1.0));
    for (var k = 11; k >= 2; k--) {
      let segK = floor(dist) + f32(k);
      let lane = obstacleLane(segK);
      if (lane < -1.5) { continue; }
      let zK = segK - dist;
      if (zK < 0.4) { continue; }
      let pK = clamp(3.0 / zK, 0.05, 1.0);
      let yK = horizon - pK * horizon;
      let cK = roadCenter(playerX, dist, zK, pK);
      let xK = cK + lane * (pK * 0.42);
      let w = pK * 0.10;
      let h = pK * 0.09;
      if (abs(uv.x - xK) < w && uv.y > yK && uv.y < yK + h) {
        let tint = hash1(segK * 13.0);
        col = mix(vec3f(0.85, 0.30, 0.15),
                  mix(vec3f(0.20, 0.40, 0.85), vec3f(0.90, 0.75, 0.20),
                      step(0.66, tint)),
                  step(0.33, tint));
        if (uv.y > yK + h * 0.55) { col *= 0.35; }
      }
    }
    // Player car: shadow, magenta body, leaning cockpit, spoiler, wheels.
    let lean = (iKeys.y - iKeys.x) * 0.012;
    let carX = 0.5 + playerX * 0.18;
    let carY = 0.115;
    let shadow = exp(-pow(length((uv - vec2f(carX, carY - 0.045))
        * vec2f(9.0, 30.0)), 2.0));
    col = mix(col, vec3f(0.02), shadow * 0.55);
    let dx = uv.x - carX;
    let dy = uv.y - carY;
    if (abs(dx) < 0.075 && abs(dy) < 0.055) {
      col = vec3f(0.95, 0.10, 0.85);
      if (dy > 0.014 && abs(dx - lean) < 0.045) {
        col = vec3f(0.20, 0.05, 0.28);
      }
      if (dy > 0.040) { col = vec3f(0.60, 0.05, 0.55); }
      if (abs(dx) > 0.055 && dy < -0.018) { col = vec3f(0.05); }
      if (iKeys.w > 0.5 && dy < -0.038) { col = vec3f(1.0, 0.15, 0.10); }
    }
  }
  col = mix(col, vec3f(0.95, 0.15, 0.10), crash * 0.35);
  // Live score HUD (top-right) + speed bar.
  let hud = drawNumber(uv, vec2f(0.66, 0.90), vec2f(0.036, 0.055), s1.y, 6);
  col = mix(col, vec3f(1.0, 0.95, 0.65), hud);
  if (uv.y > 0.945 && uv.y < 0.972 && uv.x > 0.03
      && uv.x < 0.03 + speed * 0.28) {
    col = mix(vec3f(0.20, 0.85, 0.30), vec3f(0.95, 0.25, 0.15), speed);
  }
  // Game over: dim, title, final + best score, blinking restart arrow.
  if (alive < 0.5) {
    col *= 0.30;
    let title = gameOverText(uv, vec2f(0.16, 0.60), vec2f(0.014, 0.016));
    col = mix(col, vec3f(0.95, 0.20, 0.15), title);
    let fin = drawNumber(uv, vec2f(0.32, 0.42), vec2f(0.045, 0.075), s1.y, 6);
    col = mix(col, vec3f(1.0, 0.95, 0.65), fin);
    let best = drawNumber(uv, vec2f(0.40, 0.30), vec2f(0.026, 0.042), s1.z, 6);
    col = mix(col, vec3f(0.55, 0.85, 1.00), best);
    if (fract(iTime) < 0.6) {
      let a = uv - vec2f(0.5, 0.17);
      if (a.y > 0.0 && a.y < 0.05 && abs(a.x) < (0.05 - a.y) * 0.7) {
        col = vec3f(0.30, 0.95, 0.45);
      }
      if (abs(a.x) < 0.012 && a.y > -0.045 && a.y <= 0.0) {
        col = vec3f(0.30, 0.95, 0.45);
      }
    }
  }
  return vec4f(col, 1.0);
}''';

// ═══════════════════════════════ Registry ═══════════════════════════════

final List<Showcase> showcases = [
  // UI polish
  Showcase(
    title: 'Mesh gradient',
    description: 'Stripe-style drifting color blobs for hero backgrounds',
    category: 'UI polish',
    build: () => _image(_meshGradient),
  ),
  Showcase(
    title: 'Holographic card',
    description: 'Pointer-reactive foil sheen with interference bands',
    category: 'UI polish',
    interactive: true,
    build: () => _image(_holoCard),
  ),
  Showcase(
    title: 'Shimmer skeleton',
    description: 'Loading placeholders with a sweeping highlight',
    category: 'UI polish',
    build: () => _image(_shimmer),
  ),
  Showcase(
    title: 'Neon border',
    description: 'SDF rounded-rect glow with a traveling hue',
    category: 'UI polish',
    build: () => _image(_neonBorder),
  ),
  Showcase(
    title: 'Ripple transition',
    description: 'Circular page reveal with refraction at the edge',
    category: 'UI polish',
    interactive: true,
    build: () => _image(_rippleTransition),
  ),
  // Media & imaging
  Showcase(
    title: 'Halftone print',
    description: 'Rotated CMY-style dot screen over a procedural photo',
    category: 'Media & imaging',
    build: () => _image(_halftone),
  ),
  Showcase(
    title: 'Oil paint (Kuwahara)',
    description: 'Edge-preserving quadrant filter — painterly look',
    category: 'Media & imaging',
    build: () => _image(_kuwahara),
  ),
  Showcase(
    title: 'Chromatic aberration',
    description: 'Lens fringing + film grain + vignette',
    category: 'Media & imaging',
    build: () => _image(_chromaGrain),
  ),
  Showcase(
    title: 'Bloom pipeline',
    description: 'Bright-pass buffer → blur → tonemapped composite',
    category: 'Media & imaging',
    build: () => ShadertoyEngine(
      buffers: const [
        ShadertoyPassSpec(
            language: ShadertoyLanguage.wgslSnippet, source: _bloomBufferA),
      ],
      image: const ShadertoyPassSpec(
          language: ShadertoyLanguage.wgslSnippet,
          source: _bloomImage,
          channels: _selfFeedbackChannels),
    ),
  ),
  // Simulation & generative
  Showcase(
    title: 'Reaction-diffusion',
    description: 'Gray-Scott chemicals growing Turing patterns — draw to seed',
    category: 'Simulation',
    interactive: true,
    build: () => _feedback(
        buffer: _reactionDiffusionBuffer, image: _reactionDiffusionImage),
  ),
  Showcase(
    title: 'Game of Life',
    description: 'Cellular automaton in a feedback buffer — draw cells',
    category: 'Simulation',
    interactive: true,
    build: () => _feedback(buffer: _gameOfLifeBuffer, image: _gameOfLifeImage),
  ),
  Showcase(
    title: 'Ink flow',
    description: 'Curl-noise fluid advection — drag to pour ink',
    category: 'Simulation',
    interactive: true,
    build: () => _feedback(buffer: _inkFlowBuffer, image: _inkFlowImage),
  ),
  Showcase(
    title: 'Boids flocking',
    description: '1.5k agents, full O(n²) neighbor rules on the GPU',
    category: 'Simulation',
    build: () => ParticleScene(count: 1536, pointSize: 0.008)
      ..setKernel(_boidsKernel),
  ),
  Showcase(
    title: 'Fireworks',
    description: 'Gravity, drag, and deterministic burst respawns',
    category: 'Simulation',
    build: () => ParticleScene(count: 4096, pointSize: 0.006)
      ..setKernel(_fireworksKernel),
  ),
  // Scenes & games
  Showcase(
    title: '2D dynamic light',
    description: 'SDF shapes casting soft shadows from a movable light',
    category: 'Scenes & games',
    interactive: true,
    build: () => _image(_light2d),
  ),
  Showcase(
    title: '3D racer (keyboard)',
    description: 'Endless GPU racer — arrows/WASD to steer and throttle, '
        'score climbs with speed, one crash ends the run (throttle to '
        'restart)',
    category: 'Scenes & games',
    interactive: true,
    keyboard: true,
    build: () => _feedback(buffer: _racerBuffer, image: _racerImage),
  ),
  Showcase(
    title: 'Breakout (GPU game)',
    description: 'A playable game whose entire state — ball, paddle, '
        '32 bricks — lives in GPU data texels',
    category: 'Scenes & games',
    interactive: true,
    build: () => _feedback(buffer: _breakoutBuffer, image: _breakoutImage),
  ),
  Showcase(
    title: 'Fog of war',
    description: 'Feedback buffer remembers explored terrain — drag to scout',
    category: 'Scenes & games',
    interactive: true,
    build: () => _feedback(buffer: _fogOfWarBuffer, image: _fogOfWarImage),
  ),
];

/// Deterministic initial particles helper for tests (unused by the gallery).
Float32List seedParticles(int count) {
  final data = Float32List(count * 4);
  for (var i = 0; i < count; i++) {
    data[i * 4] = (i * 37 % 200 - 100) / 100;
    data[i * 4 + 1] = (i * 53 % 200 - 100) / 100;
  }
  return data;
}
