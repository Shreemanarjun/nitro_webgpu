/// Shader-toy presets. Every preset is a full WGSL module that must declare
/// `struct U { time, width, height, param }` at `@group(0) @binding(0)` and
/// export `vs_main` / `fs_main` entry points.
library;

class ShaderPreset {
  const ShaderPreset({required this.name, required this.source});
  final String name;
  final String source;
}

/// CC0 by Marten Range (mrange), https://www.shadertoy.com/view/mslfR2 —
/// WGSL port of the DF2 "cubes" variant with a synthetic music spectrum.
const cubesPreset = ShaderPreset(name: 'Neon cubes (mslfR2)', source: r'''
// "More cubes for the cube lovers" — CC0 by Mårten Rånge (mrange)
// https://www.shadertoy.com/view/mslfR2
// WGSL port (DF2 variant) for nitro_webgpu; the Shadertoy music channel is
// replaced by a synthetic spectrum.

struct U { time: f32, width: f32, height: f32, param: f32 };
@group(0) @binding(0) var<uniform> u: U;

const PI: f32 = 3.141592654;
const TAU: f32 = 6.283185307;
const LAYERS: f32 = 5.0;
const TOLERANCE: f32 = 0.0001;
const MAX_RAY_LENGTH: f32 = 120.0;
const MAX_RAY_MARCHES_LO: i32 = 30;
const MAX_RAY_MARCHES_HI: i32 = 70;
const NORM_OFF: f32 = 0.005;

// normalize(vec3(0, 1, 0.15)), 20.0
const roadDim = vec4f(0.0, 0.9889363, 0.1483404, 20.0);
// Precomputed HSV constants (hoff = -0.025)
const glowCol1 = vec3f(0.05, 0.0875, 0.2);       // hsv(0.625, 0.75, 0.2)
const sunCol1 = vec3f(0.3375, 0.25, 0.5);        // hsv(0.725, 0.50, 0.5)
const diffCol = vec3f(0.03125, 0.125, 0.0546875); // hsv(0.375, 0.75, 0.125)
const sunDir1 = vec3f(0.3665083, 0.3665083, -0.8551861); // normalize(3,3,-7)

var<private> gRes: vec2f;
var<private> gTime: f32;
var<private> g_gd: f32;
var<private> g_rot: mat3x3f =
    mat3x3f(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0);

fn rot2(a: f32) -> mat2x2f {
  let c = cos(a);
  let s = sin(a);
  return mat2x2f(c, s, -s, c);
}

fn gmod1f(x: f32, y: f32) -> f32 { return x - y * floor(x / y); }
fn gmod2f(x: vec2f, y: vec2f) -> vec2f { return x - y * floor(x / y); }
fn gmod3f(x: vec3f, y: vec3f) -> vec3f { return x - y * floor(x / y); }

fn hsv2rgb(c: vec3f) -> vec3f {
  let k = vec4f(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
  let p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
  return c.z * mix(k.xxx, clamp(p - k.xxx, vec3f(0.0), vec3f(1.0)), c.y);
}

fn aces_approx(v_in: vec3f) -> vec3f {
  var v = max(v_in, vec3f(0.0));
  v *= 0.6;
  let a = 2.51;
  let b = 0.03;
  let c = 2.43;
  let d = 0.59;
  let e = 0.14;
  return clamp((v * (a * v + b)) / (v * (c * v + d) + e), vec3f(0.0), vec3f(1.0));
}

fn hash(co: f32) -> f32 {
  return fract(sin(co * 12.9898) * 13758.5453);
}

fn hash2(p_in: vec2f) -> vec2f {
  let p = vec2f(dot(p_in, vec2f(127.1, 311.7)), dot(p_in, vec2f(269.5, 183.3)));
  return fract(sin(p) * 43758.5453123);
}

fn blackbody(temp: f32) -> vec3f {
  var col = vec3f(255.0);
  col.x = 56100000.0 * pow(temp, -3.0 / 2.0) + 148.0;
  col.y = 100.04 * log(temp) - 623.6;
  if (temp > 6500.0) {
    col.y = 35200000.0 * pow(temp, -3.0 / 2.0) + 184.0;
  }
  col.z = 194.18 * log(temp) - 1448.6;
  col = clamp(col, vec3f(0.0), vec3f(255.0)) / 255.0;
  if (temp < 1000.0) {
    col *= temp / 1000.0;
  }
  return col * col;
}

fn tanh_approx(x: f32) -> f32 {
  let x2 = x * x;
  return clamp(x * (27.0 + x2) / (27.0 + 9.0 * x2), -1.0, 1.0);
}

fn pmin(a: f32, b: f32, k: f32) -> f32 {
  let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}

fn pmin3(a: vec3f, b: vec3f, k: f32) -> vec3f {
  let h = clamp(0.5 + 0.5 * (b - a) / k, vec3f(0.0), vec3f(1.0));
  return mix(b, a, h) - k * h * (1.0 - h);
}

fn pmax(a: f32, b: f32, k: f32) -> f32 {
  return -pmin(-a, -b, k);
}

fn pabs3(a: vec3f, k: f32) -> vec3f {
  return -pmin3(a, -a, k);
}

fn mod1(p: ptr<function, f32>, size: f32) -> f32 {
  let halfsize = size * 0.5;
  let c = floor((*p + halfsize) / size);
  *p = gmod1f(*p + halfsize, size) - halfsize;
  return c;
}

fn mod2(p: ptr<function, vec2f>, size: vec2f) -> vec2f {
  let c = floor((*p + size * 0.5) / size);
  *p = gmod2f(*p + size * 0.5, size) - size * 0.5;
  return c;
}

fn rayPlane(ro: vec3f, rd: vec3f, p: vec4f) -> f32 {
  return -(dot(ro, p.xyz) + p.w) / dot(rd, p.xyz);
}

fn circle(p: vec2f, r: f32) -> f32 {
  return length(p) - r;
}

fn torus(p: vec3f, t: vec2f) -> f32 {
  let q = vec2f(length(p.xz) - t.x, p.y);
  return length(q) - t.y;
}

fn segmentx1(p: vec2f) -> f32 {
  let d0 = abs(p.y);
  let d1 = length(p);
  return select(d1, d0, p.x > 0.0);
}

fn segmentx2(p_in: vec2f, l: f32) -> f32 {
  let hl = 0.5 * l;
  var p = p_in;
  p.x = abs(p.x);
  let d0 = abs(p.y);
  let d1 = length(p - vec2f(hl, 0.0));
  return select(d0, d1, p.x > hl);
}

fn sphere8(p_in: vec3f, r: f32) -> f32 {
  var p = p_in * p_in;
  p = p * p;
  return pow(dot(p, p), 0.125) - r;
}

fn toSpherical(p: vec3f) -> vec3f {
  let r = length(p);
  let t = acos(p.z / r);
  let ph = atan2(p.y, p.x);
  return vec3f(r, t, ph);
}

fn sun(p: vec2f) -> f32 {
  return circle(p, 0.5);
}

fn fakeFft(x: f32) -> f32 {
  let t = gTime;
  var v = 0.35 + 0.3 * sin(6.0 * x + t * 2.1) * sin(2.5 * x - t * 1.3);
  v += 0.2 * sin(15.0 * x + t * 3.7);
  return clamp(abs(v), 0.0, 1.0);
}

fn synth(p_in: vec2f, aa: f32, h: ptr<function, f32>,
         db: ptr<function, f32>) -> f32 {
  let z = 75.0;
  var p = p_in;
  p.y -= -70.0;
  let st = 0.04;
  p.x = abs(p.x);
  p.x -= 20.0 - 3.5;
  p.x += st * 20.0;
  p /= z;
  var px = p.x;
  let n = mod1(&px, st);
  p.x = px;
  let fft0 = fakeFft(n * st);
  let fft = fft0 * fft0;
  *h = fft;
  let dib = segmentx2(p.yx, fft + 0.05) - st * 0.4;
  *db = abs(p.y) * z;
  return smoothstep(aa, -aa, dib * z);
}

fn road(ro: vec3f, rd: vec3f, nrd: vec3f, glare: f32,
        pt: ptr<function, f32>) -> vec3f {
  let sm = 1.0;
  let off = abs(roadDim.w);
  let t = rayPlane(ro, rd, roadDim);
  *pt = t;

  let p = ro + rd * t;
  let np = ro + nrd * t;

  var pp = p.xz;
  let npp = np.xz;
  let opp = pp;

  let aa = length(npp - pp) * sqrt(0.5);
  pp.y += -60.0 * gTime;

  var gcol = vec3f(0.0);

  let dr = abs(pp.x) - off;
  var cp = pp;
  var cpy = cp.y;
  _ = mod1(&cpy, 6.0 * off);
  cp.y = cpy;
  var sp = pp;
  sp.x = abs(sp.x);
  var spy = sp.y;
  _ = mod1(&spy, off);
  sp.y = spy;
  let dcl = segmentx2(cp.yx, 1.5 * off);
  let dsl = segmentx2((sp - vec2f(0.95 * off, 0.0)).yx, off * 0.5);

  var mp = pp;
  _ = mod2(&mp, vec2f(off * 0.5));

  let dp = abs(mp);
  var d = dp.x;
  d = pmin(d, dp.y, sm);
  d = max(d, -dr);
  d = min(d, dcl);
  d = min(d, dsl);
  let s2 = sin(gTime + 2.0 * p.xz / off);
  var m = mix(0.75, 0.9, tanh_approx(s2.x + s2.y));
  m *= m;
  m *= m;
  m *= m;
  let hsv = vec3f(0.4 + mix(0.5, 0.0, m),
                  tanh_approx(0.15 * mix(30.0, 10.0, m) * d), 1.0);
  let fo = exp(-0.04 * max(abs(t) - off * 2.0, 0.0));
  let bcol = hsv2rgb(hsv);
  gcol += 2.0 * bcol * exp(-0.1 * mix(30.0, 10.0, m) * d) * fo;

  var sh: f32;
  var sdb: f32;
  let sd = synth(opp, 4.0 * aa, &sh, &sdb) * smoothstep(aa, -aa, -0.5 * dr);
  sh = tanh_approx(sh);
  sdb *= 0.075;
  sdb *= sdb;
  sdb += 0.05;
  let scol = sd * sdb *
      pow(tanh(vec3f(0.1) + bcol),
          mix(vec3f(1.0), vec3f(1.5, 0.5, 0.5), smoothstep(0.4, 0.5, sh)));
  gcol += scol;

  gcol = select(vec3f(0.0), gcol, t > 0.0);
  return gcol + scol;
}

fn stars(sp: vec2f, hh_in: f32) -> vec3f {
  var col = vec3f(0.0);
  let m = LAYERS;
  let hh = tanh_approx(20.0 * hh_in);

  for (var i = 0.0; i < m; i += 1.0) {
    var pp = sp + 0.5 * i;
    let s = i / (m - 1.0);
    let dim = vec2f(mix(0.05, 0.003, s) * PI);
    let np = mod2(&pp, dim);
    let h = hash2(np + 127.0 + i);
    let o = -1.0 + 2.0 * h;
    let y = sin(sp.x);
    pp += o * dim * 0.5;
    pp.y *= y;
    let l = length(pp);

    let h1 = fract(h.x * 1667.0);
    let h2 = fract(h.x * 1887.0);
    let h3 = fract(h.x * 2997.0);

    let scol = mix(8.0 * h2, 0.25 * h2 * h2, s) *
        blackbody(mix(3000.0, 20000.0, h1 * h1));

    var ccol = col +
        exp(-(mix(6000.0, 2000.0, hh) / mix(2.0, 0.25, s)) *
            max(l - 0.001, 0.0)) * scol;
    ccol *= mix(0.125, 1.0, smoothstep(1.0, 0.99, sin(0.33 * gTime + TAU * h.y)));
    col = select(col, ccol, h3 < y);
  }

  return col;
}

fn meteorite(sp: vec2f) -> vec3f {
  let period = 3.0;
  let mtime = gmod1f(gTime, period);
  let ntime = floor(gTime / period);
  let h0 = hash(ntime + 123.4);
  let h1 = fract(1667.0 * h0);
  let h2 = fract(9967.0 * h0);
  var mp = sp;
  mp.x += -1.0;
  mp.y += -0.5 * h1;
  mp.y += PI * 0.5;
  mp = mp * rot2(PI + mix(-PI / 4.0, PI / 4.0, h0));
  let m = mtime / period;
  mp.x += mix(-1.0, 2.0, m);

  let d0 = length(mp);
  let d1 = segmentx1(mp);

  var col = vec3f(0.0);

  col += 0.5 * exp(-4.0 * max(d0, 0.0)) * exp(-1000.0 * max(d1, 0.0));
  col *= 2.0 * hsv2rgb(vec3f(0.8, 0.5, 1.0));
  let fl = smoothstep(-0.5, 0.5, sin(12.0 * TAU * gTime));
  col += mix(1.0, 0.5, fl) * exp(-mix(100.0, 150.0, fl) * max(d0, 0.0));

  col = select(vec3f(0.0), col, h2 > 0.8);
  return col;
}

fn skyGrid(sp: vec2f) -> vec3f {
  let dim = vec2f(1.0 / 12.0 * PI);
  let y = sin(sp.x);
  var pp = sp;
  _ = mod2(&pp, dim * vec2f(1.0 / floor(1.0 / y), 1.0));

  var col = vec3f(0.0);
  let d = min(abs(pp.x), abs(pp.y * y));
  col += 0.25 * vec3f(0.5, 0.5, 1.0) * exp(-2000.0 * max(d - 0.00025, 0.0));
  return col;
}

fn sunset(sp_in: vec2f, nsp: vec2f) -> vec3f {
  let szoom = 0.5;
  var sp = sp_in;
  let aa = length(nsp - sp) * sqrt(0.5);
  sp -= vec2f(0.5, -0.5) * PI;
  sp /= szoom;
  sp = sp.yx;
  sp.y += 0.22;
  sp.y = -sp.y;
  let ds = sun(sp) * szoom;

  let bscol = hsv2rgb(vec3f(fract(0.7 - 0.25 * sp.y), 1.0, 1.0));
  let gscol = 0.75 * sqrt(bscol) * exp(-50.0 * max(ds, 0.0));
  let scol = mix(gscol, bscol, smoothstep(aa, -aa, ds));
  return scol;
}

fn glow(ro: vec3f, rd: vec3f, sp: vec2f, lp: vec3f) -> vec3f {
  let ld = max(dot(normalize(lp - ro), rd), 0.0);
  var y = -0.5 + sp.x / PI;
  y = max(abs(y) - 0.02, 0.0) + 0.1 * smoothstep(0.5, PI, abs(sp.y));
  let ci = pow(ld, 10.0) * 2.0 * exp(-25.0 * y);
  let col = hsv2rgb(vec3f(0.65, 0.75, 0.35 * exp(-15.0 * y))) +
      hsv2rgb(vec3f(0.8, 0.75, 0.5)) * ci;
  return col;
}

fn neonSky(ro: vec3f, rd: vec3f, nrd: vec3f, gl: ptr<function, f32>) -> vec3f {
  let lp = 500.0 * vec3f(0.0, 0.25, -1.0);
  let skyCol = hsv2rgb(vec3f(0.8, 0.75, 0.05));

  let glare = pow(abs(dot(rd, normalize(lp))), 20.0);

  let sp = toSpherical(rd.xzy).yz;
  let nsp = toSpherical(nrd.xzy).yz;
  var grd = rd;
  let g2 = grd.xy * rot2(0.025 * gTime);
  grd = vec3f(g2, grd.z);
  let spp = toSpherical(grd).yz;

  let gm = 1.0 / abs(rd.y) * mix(0.005, 2.0, glare);
  var col = skyCol * gm;
  let ig = 1.0 - glare;
  col += glow(ro, rd, sp, lp);
  if (rd.y > 0.0) {
    col += sunset(sp, nsp);
    col += stars(sp, 0.0) * ig;
    col += skyGrid(spp) * ig;
    col += meteorite(sp) * ig;
  }
  *gl = glare;
  return col;
}

fn render0(ro: vec3f, rd: vec3f, nrd: vec3f) -> vec3f {
  var glare: f32;
  var col = neonSky(ro, rd, nrd, &glare);
  if (rd.y < 0.0) {
    var t: f32;
    col += road(ro, rd, nrd, glare, &t);
  }
  return col;
}

// DF2: cubes as smooth-carved super-spheres with an orbiting torus.
fn dfeffect(p: vec3f, ogd: ptr<function, f32>) -> f32 {
  let p0 = p;
  var p1 = p;
  p1 = p1 * g_rot;
  p1 = pabs3(p1, 10.0);
  p1 -= 12.0;
  p1 = p1 * g_rot;
  let d0 = sphere8(p0, 20.0);
  let d1 = torus(p1, 10.0 * vec2f(1.0, 0.0125));

  var d = d0;
  d = pmax(d, -(d1 - 2.0), 5.0);
  d = min(d, d1);
  *ogd = d1;

  return d;
}

fn df(p_in: vec3f) -> f32 {
  var p = p_in;
  let d0 = dot(roadDim.xyz, p) + roadDim.w;
  p.y += -20.0 * 1.30;
  p.z += 66.0;
  p = p * g_rot;
  var gd1: f32;
  let d1 = dfeffect(p, &gd1);

  let d = max(d1, -d0);
  g_gd = min(g_gd, gd1);

  return d;
}

fn normalAt(pos: vec3f) -> vec3f {
  let eps = vec2f(NORM_OFF, 0.0);
  var nor: vec3f;
  nor.x = df(pos + eps.xyy) - df(pos - eps.xyy);
  nor.y = df(pos + eps.yxy) - df(pos - eps.yxy);
  nor.z = df(pos + eps.yyx) - df(pos - eps.yyx);
  return normalize(nor);
}

fn rayMarchLo(ro: vec3f, rd: vec3f, tinit: f32,
              iter: ptr<function, i32>) -> f32 {
  var t = tinit;
  var i: i32 = 0;
  loop {
    if (i >= MAX_RAY_MARCHES_LO) { break; }
    let d = df(ro + rd * t);
    if (d < TOLERANCE || t > MAX_RAY_LENGTH) { break; }
    t += d;
    i += 1;
  }
  *iter = i;
  return t;
}

fn rayMarchHi(ro: vec3f, rd: vec3f, tinit: f32,
              iter: ptr<function, i32>) -> f32 {
  var t = tinit;
  var dti = vec2f(1e10, 0.0);
  var i: i32 = 0;
  loop {
    if (i >= MAX_RAY_MARCHES_HI) { break; }
    let d = df(ro + rd * t);
    if (d < dti.x) { dti = vec2f(d, t); }
    if (d < TOLERANCE || t > MAX_RAY_LENGTH) { break; }
    t += d;
    i += 1;
  }
  if (i == MAX_RAY_MARCHES_HI) { t = dti.y; }
  *iter = i;
  return t;
}

fn rotX(a: f32) -> mat3x3f {
  let c = cos(a);
  let s = sin(a);
  return mat3x3f(1.0, 0.0, 0.0, 0.0, c, s, 0.0, -s, c);
}

fn rotY(a: f32) -> mat3x3f {
  let c = cos(a);
  let s = sin(a);
  return mat3x3f(c, 0.0, s, 0.0, 1.0, 0.0, -s, 0.0, c);
}

fn rotZ(a: f32) -> mat3x3f {
  let c = cos(a);
  let s = sin(a);
  return mat3x3f(c, s, 0.0, -s, c, 0.0, 0.0, 0.0, 1.0);
}

fn render1(col_in: vec3f, m: vec3f, ro: vec3f, rd: vec3f, nrd: vec3f) -> vec3f {
  var col = col_in;
  let tm = gTime * 0.5;
  g_rot = rotX(0.333 * tm) * rotZ(0.5 * tm) * rotY(0.23 * tm);

  var iter: i32;
  g_gd = 1e3;
  let t = rayMarchHi(ro, rd, 0.0, &iter);
  let gd = g_gd;
  let ggcol = glowCol1 * inverseSqrt(max(gd, 0.00025));
  if (t < MAX_RAY_LENGTH) {
    let p = ro + rd * t;
    let n = normalAt(p);
    let r = reflect(rd, n);
    let nr = reflect(nrd, n);
    let fre0 = 1.0 + dot(rd, n);
    var fre = fre0;
    fre *= fre;

    let ao = 1.0 - f32(iter) / f32(MAX_RAY_MARCHES_HI);
    let fo = mix(0.2, 1.0, ao);
    let rf = m * mix(0.33, 1.0, fre) * fo * 0.75;

    let fre1 = hsv2rgb(vec3f(0.8, 0.5, 1.0));
    // BOUNCE_ONCE
    g_gd = 1e3;
    var riter: i32;
    let rt = rayMarchLo(p, r, 1.0, &riter);
    let rgd = g_gd;
    let rggcol = glowCol1 * inverseSqrt(max(rgd, 0.00025));

    var rcol = clamp(rggcol, vec3f(0.0), vec3f(4.0));
    if (rt < MAX_RAY_LENGTH) {
      rcol += diffCol * 0.2;
    } else {
      rcol += render0(p, r, nr);
    }
    let dif = dot(sunDir1, n);
    col *= (1.0 - m);
    col += m * sunCol1 * dif * dif * diffCol * fo;
    col += rf * rcol * fre1;
  }

  col += clamp(m * ggcol, vec3f(0.0), vec3f(4.0));
  return col;
}

fn render2(ro: vec3f, rd: vec3f, nrd: vec3f) -> vec3f {
  var col = render0(ro, rd, nrd);

  let t = rayPlane(ro, rd, roadDim);
  let p = ro + rd * t;
  let n = roadDim.xyz;
  let r = reflect(rd, n);
  let nr = reflect(nrd, n);
  var fre = 1.0 + dot(n, rd);
  fre *= fre;

  var ro0 = ro;
  var rd0 = rd;
  var nrd0 = nrd;
  var m0 = vec3f(1.0);

  if (rd.y < -0.12) {
    ro0 = p;
    rd0 = r;
    nrd0 = nr;
    let fre0 = hsv2rgb(vec3f(0.8, 0.9, 0.1));
    let fre1 = hsv2rgb(vec3f(0.8, 0.3, 0.9));
    m0 = mix(fre0, fre1, fre);
  }

  col = render1(col, m0, ro0, rd0, nrd0);
  return col;
}

fn effect(p_in: vec2f, pp: vec2f) -> vec3f {
  let aa = 2.0 / gRes.y;
  let ro = vec3f(0.0, 0.0, 10.0);
  let la = vec3f(0.0, 2.0, 0.0);
  let up = vec3f(0.0, 1.0, 0.0);

  let ww = normalize(la - ro);
  let uu = normalize(cross(up, ww));
  let vv = cross(ww, uu);
  let fov = tan(TAU / 6.0);
  let p = p_in;
  let np = p + vec2f(aa);
  let rd = normalize(-p.x * uu + p.y * vv + fov * ww);
  let nrd = normalize(-np.x * uu + np.y * vv + fov * ww);

  var col = render2(ro, rd, nrd);
  col -= 0.0125 * vec3f(1.0, 2.0, 3.0) * (length(pp) + 0.25);
  col *= smoothstep(1.75, 0.5, length(pp));
  col = aces_approx(col);
  col = sqrt(col);
  return col;
}

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
  gRes = vec2f(u.width, u.height);
  gTime = u.time;
  let q = frag.xy / gRes;
  // Shadertoy's fragCoord is y-up; WGSL frag position is y-down.
  var p = vec2f(-1.0 + 2.0 * q.x, 1.0 - 2.0 * q.y);
  let pp = p;
  p.x *= gRes.x / gRes.y;
  let col = effect(p, pp);
  return vec4f(col, 1.0);
}
''');

const plasmaPreset = ShaderPreset(name: 'Plasma', source: r'''
struct U { time: f32, width: f32, height: f32, param: f32 };
@group(0) @binding(0) var<uniform> u: U;

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
  let uv = frag.xy / vec2f(u.width, u.height);
  let p = uv * (4.0 + 8.0 * u.param);
  let t = u.time;
  var v = sin(p.x + t);
  v += sin((p.y + t) * 0.5);
  v += sin((p.x + p.y + t) * 0.5);
  v += sin(sqrt(p.x * p.x + p.y * p.y + 1.0) + t * 1.3);
  let r = 0.5 + 0.5 * sin(v * 3.14159);
  let g = 0.5 + 0.5 * sin(v * 3.14159 + 2.0944);
  let b = 0.5 + 0.5 * sin(v * 3.14159 + 4.1888);
  return vec4f(r, g, b, 1.0);
}
''');

const tunnelPreset = ShaderPreset(name: 'Tunnel', source: r'''
struct U { time: f32, width: f32, height: f32, param: f32 };
@group(0) @binding(0) var<uniform> u: U;

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  var pos = array<vec2f, 3>(
      vec2f(-1.0, -3.0), vec2f(3.0, 1.0), vec2f(-1.0, 1.0));
  return vec4f(pos[i], 0.0, 1.0);
}
@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
  let res = vec2f(u.width, u.height);
  var p = (2.0 * frag.xy - res) / res.y;
  let a = atan2(p.y, p.x);
  let r = length(p);
  let zoom = 0.3 + 0.7 * u.param;
  let uv = vec2f(zoom / r + u.time * 0.8, a * 3.0 / 3.14159);
  let f = 0.5 + 0.5 * sin(6.28318 * uv.x) * sin(6.28318 * uv.y);
  let shade = smoothstep(0.0, 0.8, r);
  let col = vec3f(f * 0.9, f * 0.4 + 0.1 * r, 0.8 - f * 0.4) * shade;
  return vec4f(col, 1.0);
}
''');

const shaderPresets = [cubesPreset, plasmaPreset, tunnelPreset];
