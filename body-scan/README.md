# Body-scan body-fat estimator

Dependency-free ES module that turns a 360° body-scan video into a body-fat
estimate with an honest 95% range. Works with MediaPipe Pose
(`enableSegmentation: true`) or any pose model that gives 33 normalized
landmarks plus a person mask.

## Use

```js
import { estimateBodyFat, aggregateScans, measureFrameQuality } from './bodyFatEstimator.js';

// For each sampled video frame (8–15 fps is plenty):
const q = measureFrameQuality(ctx.getImageData(0, 0, w, h));
frames.push({
  landmarks: result.poseLandmarks,          // [{x,y,z,visibility}] 0..1
  mask: { width, height, data },            // Float32Array 0..1 or Uint8Array 0..255
  sharpness: q.sharpness, brightness: q.brightness,
});

const result = estimateBodyFat({
  frames,
  profile: {
    sex: 'male', age: 32, heightIn: 70, weightLbs: 172,
    tape: { neck: 15, waist: 33, hip: 38 },  // optional "Accuracy details" fields
  },
  options: {
    minSharpness: 60, minBrightness: 50, maxBrightness: 235,
    shapeFactors: savedUser.calibration,     // from a previous scan, if any
  },
});
// result.bodyFatPct, result.ci95, result.confidence, result.warnings, result.calibration
```

Save `result.calibration` with the user whenever they've entered tape
measurements, and pass it back as `options.shapeFactors` on later scans. That
corrects the video for that person's body shape and is the single biggest
accuracy gain.

For the "Averaged across scans" card, use `aggregateScans` instead of a raw
mean ± spread:

```js
aggregateScans(history.map(s => ({
  bodyFatPct: s.bodyFatPct, measurementSd: s.measurementSd, modelSd: s.modelSd, takenAt: s.date,
})));
// → { bodyFatPct, plusMinus, scansUsed, scansDropped, confidence, hint }
```

## Recording tips to show the user

- Phone at waist height, 6–8 ft away, whole body in frame head to heels.
- Fitted clothing; arms slightly out from the body (A-pose).
- Turn slowly through a full 360° (~10 s). Side views are what measure depth.

## Test

```bash
node --test body-scan/
```
