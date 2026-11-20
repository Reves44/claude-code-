# MUR Nutrition: Body Scanner (iOS)

Measures height and neck, chest, waist and hip circumference with the iPhone's rear camera and depth sensor.
It then estimates body fat from those measurements.

## Files

| File | What it does |
|---|---|
| `BodyScanCamera.swift` | Sets up the camera for measuring: LiDAR first, highest-resolution depth map, stabilisation **off**, colour and depth frames in sync. Also tracks phone tilt and shake. |
| `ScanQualityGate.swift` | Rejects any frame that would give a bad reading: body cut off, unsure joints, too close or far, phone tilted or moving, person moving, bad lighting, wrong pose. |
| `BodyGeometry.swift` | Converts depth pixels to real centimetres with the lens's focal length and finds the neck, chest, waist and hip lines. Turns front width plus side depth into a circumference. Uses outlier-proof statistics. |
| `BodyScanSession.swift` | Runs the scan: 30 good frames facing the camera, then 30 side-on. Combines them, applies the height and calibration corrections and works out body fat. |
| `BodyScanView.swift` | SwiftUI screen with live preview, coaching messages and results. |

## Requirements

- iOS 17+ (uses `VNDetectHumanBodyPose3DRequest` with depth).
- An iPhone with a rear depth camera. **LiDAR (iPhone 12 Pro and later Pro models) is strongly recommended.** Dual-camera depth works but is noticeably less accurate.
- Add to `Info.plist`: `NSCameraUsageDescription` and `NSMotionUsageDescription`.
- Show it with `BodyScanView()`.

## How to get an accurate scan

1. Prop the phone upright at waist height, 2–2.5 m from the person.
2. Stand at least 1 m in front of a plain wall. The scanner separates body from background by depth.
3. Wear fitted clothing. Loose clothing gets measured as body.
4. Enter your tape-measured height. The scanner uses it to correct the overall scale, which is the biggest single accuracy gain.

## About "100% accuracy"

No camera-based scanner is 100% accurate. Even two trained people with a tape measure disagree by about 1 cm on a waist.
This code is built to get as close as the hardware allows: strict frame rejection, many frames combined, and scale correction from known height.
The ± number on each result is the **repeatability** of the scan. It is not the true error.

To find the real error and correct it:

1. Scan 10 or more people and tape-measure the same spots by hand.
2. For each measurement, average `tape ÷ scan`.
3. Put those averages into `ScanCalibration` (`neck`, `chest`, `waist`, `hip`).
4. Re-check on a new group of people.

Body fat uses the U.S. Navy formula. Its published error is roughly ±3–4 percentage points, even with perfect tape measurements.
Show it in the app as an estimate.

## Not yet verified

This code was written without a Mac, so it has **not been compiled or run on a device**. Check these first:

- `uprightToNative` in `BodyGeometry.swift`: the portrait-to-sensor coordinate conversion. If the measurement lines land in the wrong place, this is the cause.
- The `chest`, `waist`, `hip` and `neck` line positions in `BodyGeometry.landmarks`. They are anatomical starting points to tune against real tape measurements.
