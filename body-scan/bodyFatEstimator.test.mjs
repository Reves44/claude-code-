// Run: node --test body-scan/
// Renders a synthetic person rotating 360° with known neck/waist/hip and checks
// that the estimator recovers them.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  estimateBodyFat, aggregateScans, ellipseCircumference, navyBodyFat, LM,
} from './bodyFatEstimator.js';

const W = 720, H = 1280, TOP = 90, HEIGHT_IN = 70, HEIGHT_PX = 1100;
const S = HEIGHT_PX / HEIGHT_IN; // px per inch
const CX = 360;

// [front width, depth] in inches by height-from-top
function profileAt(u) {
  if (u < 9) return [6, 7.5];     // head
  if (u < 11.5) return [4.6, 4.6]; // neck
  if (u < 13) return [17, 9];      // shoulders
  if (u < 20) return [13, 9.5];    // chest
  if (u < 30) return [12, 9];      // waist
  if (u < 37) return [14, 10];     // hips
  return [12, 7];                  // legs
}
const TRUTH = {
  neck: ellipseCircumference(4.6, 4.6),
  waist: ellipseCircumference(12, 9),
  hip: ellipseCircumference(14, 10),
};

function rng(seed) {
  return () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
}

function makeFrame(theta, rand, { noise = true } = {}) {
  const c = Math.cos(theta), s = Math.sin(theta);
  const data = new Uint8Array(W * H);
  for (let y = TOP; y < TOP + HEIGHT_PX; y++) {
    const [a, b] = profileAt((y - TOP) / S);
    const half = (Math.sqrt((a * c) ** 2 + (b * s) ** 2) / 2) * S;
    const jl = noise ? Math.round((rand() - 0.5) * 2) : 0;
    const jr = noise ? Math.round((rand() - 0.5) * 2) : 0;
    for (let x = Math.round(CX - half) + jl; x <= Math.round(CX + half) + jr; x++) data[y * W + x] = 255;
  }
  const lm = Array.from({ length: 33 }, () => ({ x: 0.5, y: 0.5, visibility: 0.2 }));
  const put = (i, u, dxIn) => {
    const j = noise ? (rand() - 0.5) * 4 : 0;
    lm[i] = { x: (CX + dxIn * c * S + j) / W, y: (TOP + u * S + j) / H, visibility: 0.99 };
  };
  put(LM.NOSE, 5, 0);
  put(LM.MOUTH_L, 7.5, 1); put(LM.MOUTH_R, 7.5, -1);
  put(LM.L_SHOULDER, 12.5, 7); put(LM.R_SHOULDER, 12.5, -7);
  put(LM.L_ELBOW, 24, 11); put(LM.R_ELBOW, 24, -11);
  put(LM.L_WRIST, 34, 12); put(LM.R_WRIST, 34, -12);
  put(LM.L_HIP, 33, 4); put(LM.R_HIP, 33, -4);
  put(LM.L_KNEE, 51, 3.5); put(LM.R_KNEE, 51, -3.5);
  put(LM.L_ANKLE, 66, 3); put(LM.R_ANKLE, 66, -3);
  put(LM.L_HEEL, 69.6, 3); put(LM.R_HEEL, 69.6, -3);
  return { landmarks: lm, mask: { width: W, height: H, data } };
}

const profile = { sex: 'male', age: 32, heightIn: HEIGHT_IN, weightLbs: 172 };

test('recovers circumferences from a 360° rotation within 3%', () => {
  const rand = rng(7);
  const frames = Array.from({ length: 72 }, (_, i) => makeFrame((i / 72) * 2 * Math.PI, rand));
  const r = estimateBodyFat({ frames, profile, options: { bootstrapSamples: 60 } });
  assert.equal(r.ok, true, r.error);
  for (const k of ['neck', 'waist', 'hip']) {
    const err = Math.abs(r.circumferencesIn[k] - TRUTH[k]) / TRUTH[k];
    assert.ok(err < 0.03, `${k}: got ${r.circumferencesIn[k]}, want ${TRUTH[k].toFixed(1)} (${(err * 100).toFixed(1)}%)`);
  }
  const navyTruth = navyBodyFat({ ...profile, neck: TRUTH.neck, waist: TRUTH.waist });
  const navyVideo = r.methods.find((m) => m.name === 'US Navy (video)').value;
  assert.ok(Math.abs(navyVideo - navyTruth) < 1.5, `navy ${navyVideo} vs ${navyTruth.toFixed(1)}`);
  assert.equal(r.warnings.length, 0);
  console.log('360° result:', JSON.stringify(r, null, 1));
});

test('front-only video falls back to estimated depth and warns', () => {
  const rand = rng(3);
  const frames = Array.from({ length: 30 }, (_, i) => makeFrame((i - 15) * 0.01, rand));
  const r = estimateBodyFat({ frames, profile, options: { bootstrapSamples: 30 } });
  assert.equal(r.ok, true);
  assert.ok(r.warnings.some((w) => w.includes('No side view')));
});

test('rejects frames with the body cut off', () => {
  const rand = rng(1);
  const frames = Array.from({ length: 20 }, (_, i) => {
    const f = makeFrame(i * 0.3, rand);
    f.mask.data.fill(255, 0, W * 5); // silhouette touching the top edge
    return f;
  });
  const r = estimateBodyFat({ frames, profile });
  assert.equal(r.ok, false);
  assert.ok(r.frames.rejected['body cut off'] > 0);
});

test('aggregateScans keeps a sensible range with 2 scans and drops outliers', () => {
  const two = aggregateScans([
    { bodyFatPct: 15, measurementSd: 0.8, modelSd: 2.5, takenAt: '2026-11-20' },
    { bodyFatPct: 16, measurementSd: 0.8, modelSd: 2.5, takenAt: '2026-11-22' },
  ]);
  assert.equal(two.bodyFatPct, 15.5);
  assert.ok(two.plusMinus < 6, `±${two.plusMinus}`);
  assert.equal(two.confidence, 'low');

  const withOutlier = aggregateScans([
    { bodyFatPct: 15, measurementSd: 0.8, modelSd: 2.5, takenAt: '2026-11-18' },
    { bodyFatPct: 15.6, measurementSd: 0.8, modelSd: 2.5, takenAt: '2026-11-20' },
    { bodyFatPct: 15.2, measurementSd: 0.8, modelSd: 2.5, takenAt: '2026-11-21' },
    { bodyFatPct: 29, measurementSd: 0.8, modelSd: 2.5, takenAt: '2026-11-22' },
  ]);
  assert.equal(withOutlier.scansDropped, 1);
  assert.ok(Math.abs(withOutlier.bodyFatPct - 15.3) < 0.3);
});
