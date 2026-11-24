/**
 * Body-fat estimation from a 360° body-scan video.
 *
 * Why the old number was noisy: a single front-facing frame only gives body
 * *width*, so circumferences (and therefore body fat) had to be guessed.
 * This module uses the whole rotation instead:
 *
 *  1. Quality gate every frame (landmark visibility, full body in frame,
 *     standing straight, optional sharpness/brightness).
 *  2. Self-calibrate scale per frame from the user's height (pixels head-to-heel),
 *     so walking closer/farther from the camera doesn't matter.
 *  3. Measure silhouette width at the neck, waist and hip on each frame and
 *     estimate how far the body is turned from the shoulder spread.
 *  4. Fit an ellipse to width-vs-rotation for each level:
 *        width(θ)² = front² · cos²θ + depth² · sin²θ
 *     using every frame (robust least squares), then convert to a
 *     circumference with Ramanujan's formula.
 *  5. Run several validated equations (US Navy, Relative Fat Mass, Deurenberg,
 *     tape-measure Navy if provided) and combine them by inverse variance.
 *  6. Bootstrap over frames to get a real measurement uncertainty, and report
 *     a 95% range that combines it with each equation's published error.
 *
 * Input frames are framework-agnostic; MediaPipe Pose (33 landmarks, normalized
 * 0..1 coordinates, with `enableSegmentation: true`) matches directly.
 *
 * All lengths are inches, weight is lbs.
 */

// MediaPipe Pose landmark indices
export const LM = {
  NOSE: 0, MOUTH_L: 9, MOUTH_R: 10,
  L_SHOULDER: 11, R_SHOULDER: 12, L_ELBOW: 13, R_ELBOW: 14,
  L_WRIST: 15, R_WRIST: 16, L_HIP: 23, R_HIP: 24,
  L_KNEE: 25, R_KNEE: 26, L_ANKLE: 27, R_ANKLE: 28,
  L_HEEL: 29, R_HEEL: 30,
};

export const DEFAULTS = {
  minVisibility: 0.5,
  minKneeAngleDeg: 160,       // reject frames where the user is bending
  minSharpness: null,         // e.g. 60 (variance of Laplacian), if you pass frame.sharpness
  minBrightness: null,        // e.g. 50 (0..255), if you pass frame.brightness
  maxBrightness: null,        // e.g. 235
  maskThreshold: 0.5,
  minValidFrames: 12,
  minFramesPerLevel: 8,
  sideViewCos: 0.45,          // need at least one frame turned this far for a true depth reading
  frontViewCos: 0.9,
  armCheckCos: 0.6,           // on frontal frames, drop a level if an arm overlaps the torso
  shapeFactors: { neck: 1, waist: 1, hip: 1 }, // learned per user via `calibration`, see README
  fallbackDepthRatio: { neck: 0.95, waist: 0.78, hip: 0.72 },
  bootstrapSamples: 200,
  methodCorrelation: 0.5,     // the equations share inputs; don't treat them as independent
  seed: 12345,
};

// Published standard errors of estimate vs. DEXA / hydrostatic weighing (% body fat)
const SEE = { navy: 3.7, rfm: 3.8, deurenberg: 4.1, tapeError: 1.0 };

// ---------------------------------------------------------------- frame helpers

/** Sharpness (variance of Laplacian) and mean brightness from RGBA ImageData. */
export function measureFrameQuality(imageData, step = 2) {
  const { width: w, height: h, data } = imageData;
  const lum = (x, y) => {
    const i = (y * w + x) * 4;
    return 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
  };
  let sum = 0, sumSq = 0, n = 0, bright = 0, bn = 0;
  for (let y = step; y < h - step; y += step) {
    for (let x = step; x < w - step; x += step) {
      const c = lum(x, y);
      const lap = lum(x - step, y) + lum(x + step, y) + lum(x, y - step) + lum(x, y + step) - 4 * c;
      sum += lap; sumSq += lap * lap; n++;
      bright += c; bn++;
    }
  }
  const mean = sum / n;
  return { sharpness: sumSq / n - mean * mean, brightness: bright / bn };
}

function makeMaskReader(mask, threshold) {
  const { width, height, data } = mask;
  const scale = (data instanceof Uint8Array || data instanceof Uint8ClampedArray) ? 255 : 1;
  const t = threshold * scale;
  return {
    width, height,
    on(x, y) {
      x = Math.round(x); y = Math.round(y);
      if (x < 0 || y < 0 || x >= width || y >= height) return false;
      return data[y * width + x] >= t;
    },
  };
}

/** Width of the contiguous silhouette run that contains (or is nearest) cx on a row. */
function runAt(m, row, cx, searchRadius) {
  let start = null;
  for (let d = 0; d <= searchRadius; d++) {
    if (m.on(cx - d, row)) { start = cx - d; break; }
    if (m.on(cx + d, row)) { start = cx + d; break; }
  }
  if (start === null) return null;
  let l = Math.round(start), r = Math.round(start);
  while (m.on(l - 1, row)) l--;
  while (m.on(r + 1, row)) r++;
  return { left: l, right: r, width: r - l + 1 };
}

const visible = (p, min) => p && (p.visibility === undefined || p.visibility >= min);

function angleDeg(a, b, c) {
  const v1x = a.x - b.x, v1y = a.y - b.y, v2x = c.x - b.x, v2y = c.y - b.y;
  const cos = (v1x * v2x + v1y * v2y) / (Math.hypot(v1x, v1y) * Math.hypot(v2x, v2y) || 1);
  return (Math.acos(Math.max(-1, Math.min(1, cos))) * 180) / Math.PI;
}

/**
 * Measure one frame. Returns { ok: false, reason } or
 * { ok: true, spread, levels: { neck|waist|hip: { width, armInside } } } with widths in inches.
 */
export function analyzeFrame(frame, profile, opts = DEFAULTS) {
  const o = { ...DEFAULTS, ...opts };
  const { landmarks, mask } = frame;
  if (!landmarks || !mask) return { ok: false, reason: 'missing data' };

  if (o.minSharpness != null && frame.sharpness != null && frame.sharpness < o.minSharpness)
    return { ok: false, reason: 'blurry' };
  if (o.minBrightness != null && frame.brightness != null && frame.brightness < o.minBrightness)
    return { ok: false, reason: 'too dark' };
  if (o.maxBrightness != null && frame.brightness != null && frame.brightness > o.maxBrightness)
    return { ok: false, reason: 'overexposed' };

  const m = makeMaskReader(mask, o.maskThreshold);
  const P = (i) => {
    const p = landmarks[i];
    return p ? { x: p.x * m.width, y: p.y * m.height, visibility: p.visibility } : null;
  };
  const vis = (i) => visible(landmarks[i], o.minVisibility);

  const required = [LM.NOSE, LM.L_SHOULDER, LM.R_SHOULDER, LM.L_HIP, LM.R_HIP];
  if (!required.every(vis)) return { ok: false, reason: 'pose not visible' };
  const heels = [LM.L_HEEL, LM.R_HEEL, LM.L_ANKLE, LM.R_ANKLE].filter(vis).map(P);
  if (!heels.length) return { ok: false, reason: 'feet not visible' };

  // Standing straight?
  for (const [h, k, a] of [[LM.L_HIP, LM.L_KNEE, LM.L_ANKLE], [LM.R_HIP, LM.R_KNEE, LM.R_ANKLE]]) {
    if (vis(h) && vis(k) && vis(a) && angleDeg(P(h), P(k), P(a)) < o.minKneeAngleDeg)
      return { ok: false, reason: 'not standing straight' };
  }

  const ls = P(LM.L_SHOULDER), rs = P(LM.R_SHOULDER), lh = P(LM.L_HIP), rh = P(LM.R_HIP);
  const shoulderY = (ls.y + rs.y) / 2, hipY = (lh.y + rh.y) / 2;
  const T = hipY - shoulderY;
  if (T <= 4) return { ok: false, reason: 'pose not visible' };
  const cx = (ls.x + rs.x + lh.x + rh.x) / 4;

  // Head-to-heel height in pixels (mask top, landmark/mask bottom)
  const band = Math.max(T, 10);
  let top = -1, bottom = -1;
  for (let y = 0; y < m.height && top < 0; y++)
    for (let x = cx - band; x <= cx + band; x += 1) if (m.on(x, y)) { top = y; break; }
  for (let y = m.height - 1; y >= 0 && bottom < 0; y--)
    for (let x = cx - 2 * band; x <= cx + 2 * band; x += 1) if (m.on(x, y)) { bottom = y; break; }
  if (top < 0 || bottom < 0) return { ok: false, reason: 'no silhouette' };
  if (top <= 1 || bottom >= m.height - 2) return { ok: false, reason: 'body cut off' };
  const heelY = Math.max(...heels.map((p) => p.y));
  if (Math.abs(bottom - heelY) > 0.04 * (bottom - top)) bottom = heelY; // shadows / floor bleed
  const heightPx = bottom - top;
  if (heightPx < 0.4 * m.height) return { ok: false, reason: 'too far from camera' };
  const inPerPx = profile.heightIn / heightPx;

  const mouthY = vis(LM.MOUTH_L) && vis(LM.MOUTH_R)
    ? (P(LM.MOUTH_L).y + P(LM.MOUTH_R).y) / 2
    : P(LM.NOSE).y + 0.25 * (shoulderY - P(LM.NOSE).y);
  const neckSpan = shoulderY - mouthY;

  const arms = [LM.L_ELBOW, LM.R_ELBOW, LM.L_WRIST, LM.R_WRIST].filter(vis).map(P);
  const measureBand = (y0, y1, pick) => {
    let best = null;
    const rows = [];
    for (let y = Math.round(y0); y <= Math.round(y1); y++) {
      const r = runAt(m, y, cx, band * 0.5);
      if (r) rows.push({ y, ...r });
    }
    if (rows.length < 3) return null;
    // 3-row median to suppress mask jitter
    for (let i = 1; i < rows.length - 1; i++) {
      const w = median([rows[i - 1].width, rows[i].width, rows[i + 1].width]);
      if (!best || (pick === 'min' ? w < best.w : w > best.w)) best = { w, row: rows[i] };
    }
    return best;
  };
  const averageBand = (y0, y1) => {
    const ws = [];
    let mid = null;
    for (let y = Math.round(y0); y <= Math.round(y1); y++) {
      const r = runAt(m, y, cx, band * 0.5);
      if (r) { ws.push(r.width); if (!mid || Math.abs(y - (y0 + y1) / 2) < 1) mid = { y, ...r }; }
    }
    return ws.length >= 3 ? { w: median(ws), row: mid } : null;
  };

  const female = profile.sex === 'female';
  const raw = {
    neck: measureBand(mouthY + 0.35 * neckSpan, shoulderY - 0.2 * neckSpan, 'min'),
    // Navy protocol: men at the navel, women at the narrowest point
    waist: female
      ? measureBand(shoulderY + 0.45 * T, hipY - 0.15 * T, 'min')
      : averageBand(hipY - 0.3 * T, hipY - 0.2 * T),
    hip: measureBand(hipY - 0.05 * T, hipY + 0.3 * T, 'max'),
  };

  const levels = {};
  for (const [k, v] of Object.entries(raw)) {
    if (!v) continue;
    const armInside = arms.some(
      (a) => Math.abs(a.y - v.row.y) < 0.15 * T && a.x >= v.row.left && a.x <= v.row.right,
    );
    levels[k] = { width: v.w * inPerPx, armInside };
  }
  return { ok: true, spread: Math.abs(ls.x - rs.x) / heightPx, levels };
}

// --------------------------------------------------------------- fitting

const median = (a) => {
  const s = [...a].sort((x, y) => x - y), n = s.length;
  return n ? (n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2) : NaN;
};
const percentile = (a, p) => {
  const s = [...a].sort((x, y) => x - y);
  const i = (s.length - 1) * p, lo = Math.floor(i), hi = Math.ceil(i);
  return s[lo] + (s[hi] - s[lo]) * (i - lo);
};
const sd = (a) => {
  const m = a.reduce((s, x) => s + x, 0) / a.length;
  return Math.sqrt(a.reduce((s, x) => s + (x - m) ** 2, 0) / Math.max(1, a.length - 1));
};

/** Ellipse perimeter (Ramanujan II) from full front width and depth. */
export function ellipseCircumference(front, depth) {
  const a = front / 2, b = depth / 2, h = ((a - b) / (a + b)) ** 2;
  return Math.PI * (a + b) * (1 + (3 * h) / (10 + Math.sqrt(4 - 3 * h)));
}

/** Least-squares fit of w² = F²c² + D²(1-c²) with one round of outlier trimming. */
function fitEllipse(points) {
  const solve = (pts) => {
    let scc = 0, sss = 0, scs = 0, scw = 0, ssw = 0;
    for (const { c, w } of pts) {
      const c2 = c * c, s2 = 1 - c2, w2 = w * w;
      scc += c2 * c2; sss += s2 * s2; scs += c2 * s2; scw += c2 * w2; ssw += s2 * w2;
    }
    const det = scc * sss - scs * scs;
    if (Math.abs(det) < 1e-9) return null;
    const F2 = (scw * sss - ssw * scs) / det, D2 = (ssw * scc - scw * scs) / det;
    return F2 > 0 && D2 > 0 ? { front: Math.sqrt(F2), depth: Math.sqrt(D2) } : null;
  };
  let fit = solve(points);
  if (!fit) return null;
  const pred = (c) => Math.sqrt(fit.front ** 2 * c * c + fit.depth ** 2 * (1 - c * c));
  const res = points.map((p) => p.w - pred(p.c));
  const mad = 1.4826 * median(res.map(Math.abs)) || 1e-6;
  const kept = points.filter((_, i) => Math.abs(res[i]) <= 3 * mad);
  if (kept.length >= 5) fit = solve(kept) || fit;
  return fit;
}

function circumferences(records, o) {
  const spreads = records.map((r) => r.spread);
  const maxSpread = percentile(spreads, 0.95) || 1e-6;
  const out = {}, warnings = [];
  for (const level of ['neck', 'waist', 'hip']) {
    const pts = [];
    for (const r of records) {
      const L = r.levels[level];
      if (!L) continue;
      const c = Math.min(1, r.spread / maxSpread);
      if (L.armInside && c > o.armCheckCos) continue;
      pts.push({ c, w: L.width });
    }
    if (pts.length < o.minFramesPerLevel) { out[level] = null; continue; }
    const cs = pts.map((p) => p.c);
    const hasSide = Math.min(...cs) <= o.sideViewCos, hasFront = Math.max(...cs) >= o.frontViewCos;
    let fit = hasSide && hasFront ? fitEllipse(pts) : null;
    let measured = !!fit;
    if (!fit) {
      const fronts = pts.filter((p) => p.c >= o.frontViewCos).map((p) => p.w);
      const front = fronts.length ? median(fronts) : Math.max(...pts.map((p) => p.w));
      fit = { front, depth: front * o.fallbackDepthRatio[level] };
      measured = false;
    }
    out[level] = {
      raw: ellipseCircumference(fit.front, fit.depth),
      value: ellipseCircumference(fit.front, fit.depth) * (o.shapeFactors[level] ?? 1),
      front: fit.front, depth: fit.depth, measuredDepth: measured, frames: pts.length,
    };
    if (!measured) warnings.push(`No side view for ${level}: depth was estimated. Turn a full 360° for a better reading.`);
  }
  return { circ: out, warnings };
}

// --------------------------------------------------------------- equations

export function navyBodyFat({ sex, heightIn, neck, waist, hip }) {
  if (sex === 'female') {
    if (!(waist + hip - neck > 0)) return NaN;
    return 163.205 * Math.log10(waist + hip - neck) - 97.684 * Math.log10(heightIn) - 78.387;
  }
  if (!(waist - neck > 0)) return NaN;
  return 86.01 * Math.log10(waist - neck) - 70.041 * Math.log10(heightIn) + 36.76;
}

/** Relative Fat Mass (Woolcott & Bergman 2018). */
export const rfmBodyFat = ({ sex, heightIn, waist }) => 64 - 20 * (heightIn / waist) + (sex === 'female' ? 12 : 0);

/** Deurenberg 1991, BMI + age based. */
export function deurenbergBodyFat({ sex, heightIn, weightLbs, age }) {
  const bmi = (703 * weightLbs) / (heightIn * heightIn);
  return 1.2 * bmi + 0.23 * age - 10.8 * (sex === 'female' ? 0 : 1) - 5.4;
}

function videoEstimates(profile, circ) {
  const neck = circ.neck?.value, waist = circ.waist?.value, hip = circ.hip?.value;
  const r = {};
  if (neck && waist && (profile.sex !== 'female' || hip))
    r.navy = navyBodyFat({ ...profile, neck, waist, hip });
  if (waist) r.rfm = rfmBodyFat({ ...profile, waist });
  return r;
}

function mulberry32(seed) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const clampBf = (x) => Math.max(2, Math.min(60, x));

// --------------------------------------------------------------- main entry

/**
 * @param {object}   args
 * @param {Array}    args.frames   [{ landmarks, mask:{width,height,data}, sharpness?, brightness? }]
 * @param {object}   args.profile  { sex:'male'|'female', age, heightIn, weightLbs?, tape?:{neck,waist,hip} }
 * @param {object}  [args.options] overrides for DEFAULTS
 */
export function estimateBodyFat({ frames, profile, options = {} }) {
  const o = { ...DEFAULTS, ...options, shapeFactors: { ...DEFAULTS.shapeFactors, ...(options.shapeFactors || {}) } };
  if (!profile?.heightIn || !profile?.sex) throw new Error('profile.heightIn and profile.sex are required');

  const rejected = {};
  const records = [];
  for (const f of frames) {
    const r = analyzeFrame(f, profile, o);
    if (r.ok) records.push(r);
    else rejected[r.reason] = (rejected[r.reason] || 0) + 1;
  }
  const frameStats = { total: frames.length, used: records.length, rejected };
  if (records.length < o.minValidFrames) {
    return { ok: false, error: 'Not enough usable frames. Retake in good light with your whole body in view.', frames: frameStats };
  }

  const { circ, warnings } = circumferences(records, o);
  const point = videoEstimates(profile, circ);

  // Bootstrap over frames → measurement uncertainty of the video-based equations
  const rand = mulberry32(o.seed);
  const boots = { navy: [], rfm: [] };
  for (let b = 0; b < o.bootstrapSamples; b++) {
    const sample = Array.from({ length: records.length }, () => records[Math.floor(rand() * records.length)]);
    const { circ: c } = circumferences(sample, o);
    const e = videoEstimates(profile, c);
    for (const k of Object.keys(boots)) if (Number.isFinite(e[k])) boots[k].push(e[k]);
  }

  const methods = [];
  for (const k of ['navy', 'rfm']) {
    if (!Number.isFinite(point[k])) continue;
    const measSd = boots[k].length > 10 ? sd(boots[k]) : 3;
    const depthPenalty = ['neck', 'waist', 'hip'].some((l) => circ[l] && !circ[l].measuredDepth) ? 2 : 0;
    methods.push({
      name: k === 'navy' ? 'US Navy (video)' : 'Relative Fat Mass (video)',
      value: point[k], modelSd: SEE[k], measurementSd: Math.hypot(measSd, depthPenalty),
    });
  }
  const t = profile.tape;
  if (t?.neck && t?.waist && (profile.sex !== 'female' || t?.hip)) {
    const v = navyBodyFat({ ...profile, ...t });
    if (Number.isFinite(v)) methods.push({ name: 'US Navy (tape)', value: v, modelSd: SEE.navy, measurementSd: SEE.tapeError });
  }
  if (profile.weightLbs && profile.age) {
    methods.push({ name: 'Deurenberg (BMI + age)', value: deurenbergBodyFat(profile), modelSd: SEE.deurenberg, measurementSd: 0.3 });
  }
  if (!methods.length) return { ok: false, error: 'Could not measure neck/waist from the video.', frames: frameStats };

  // Inverse-variance combination, inflated for correlation between methods
  let sw = 0, swx = 0, swm = 0, swMeas = 0;
  for (const m of methods) {
    m.sd = Math.hypot(m.modelSd, m.measurementSd);
    const w = 1 / m.sd ** 2;
    sw += w; swx += w * m.value; swm += w * m.modelSd; swMeas += w * m.measurementSd ** 2;
  }
  const n = methods.length;
  const inflate = Math.sqrt(1 + o.methodCorrelation * (n - 1));
  const bodyFat = clampBf(swx / sw);
  const sdTotal = Math.sqrt(1 / sw) * inflate;
  const measurementSd = Math.sqrt(swMeas / sw);
  const modelSd = Math.sqrt(Math.max(0, sdTotal ** 2 - measurementSd ** 2));

  // Per-user calibration: if tape measurements exist, learn how the video ellipse
  // relates to the real tape. Save these and pass back as options.shapeFactors next scan.
  const calibration = {};
  for (const l of ['neck', 'waist', 'hip']) {
    if (t?.[l] && circ[l]) calibration[l] = +(t[l] / circ[l].raw).toFixed(3);
  }

  const r1 = (x) => Math.round(x * 10) / 10;
  return {
    ok: true,
    bodyFatPct: r1(bodyFat),
    ci95: [r1(clampBf(bodyFat - 1.96 * sdTotal)), r1(clampBf(bodyFat + 1.96 * sdTotal))],
    sd: r1(sdTotal), measurementSd: r1(measurementSd), modelSd: r1(modelSd),
    confidence: sdTotal <= 3 ? 'high' : sdTotal <= 4.5 ? 'medium' : 'low',
    methods: methods.map((m) => ({ name: m.name, value: r1(m.value), sd: r1(m.sd) })),
    circumferencesIn: Object.fromEntries(Object.entries(circ).map(([k, v]) => [k, v ? r1(v.value) : null])),
    calibration,
    frames: frameStats,
    warnings,
  };
}

/**
 * Combine several scans into one reading (replaces "±6.9 from 2 readings").
 * Frame noise averages out across scans; equation error does not, so it is
 * kept as a floor. Scans older than `maxAgeDays` before the newest are ignored,
 * and with ≥3 scans clear outliers are dropped.
 *
 * @param {Array} scans [{ bodyFatPct, measurementSd, modelSd, takenAt }]
 */
export function aggregateScans(scans, { maxAgeDays = 14 } = {}) {
  if (!scans.length) return null;
  const newest = Math.max(...scans.map((s) => +new Date(s.takenAt)));
  let use = scans.filter((s) => newest - +new Date(s.takenAt) <= maxAgeDays * 864e5);
  if (use.length >= 3) {
    const med = median(use.map((s) => s.bodyFatPct));
    const mad = Math.max(1, 1.4826 * median(use.map((s) => Math.abs(s.bodyFatPct - med))));
    use = use.filter((s) => Math.abs(s.bodyFatPct - med) <= 3 * mad);
  }
  let sw = 0, swx = 0;
  for (const s of use) {
    const w = 1 / Math.max(0.5, s.measurementSd) ** 2;
    sw += w; swx += w * s.bodyFatPct;
  }
  const mean = swx / sw;
  let measVar = 1 / sw;
  if (use.length >= 2) measVar = Math.max(measVar, sd(use.map((s) => s.bodyFatPct)) ** 2 / use.length);
  const modelSd = median(use.map((s) => s.modelSd));
  const total = Math.sqrt(measVar + modelSd ** 2);
  const r1 = (x) => Math.round(x * 10) / 10;
  return {
    bodyFatPct: r1(mean),
    plusMinus: r1(1.96 * total),
    scansUsed: use.length,
    scansDropped: scans.length - use.length,
    confidence: use.length < 3 ? 'low' : total <= 3 ? 'high' : 'medium',
    hint: use.length < 3 ? 'Add another scan to raise confidence.' : null,
  };
}
