import AVFoundation
import Vision
import simd

// MARK: - Coordinate spaces
//
// Vision is run with orientation `.right` (rear camera, phone held in portrait), so joint positions
// come back normalised in the UPRIGHT portrait image with the origin at the BOTTOM-LEFT.
// The depth map is in the sensor-native LANDSCAPE orientation with the origin at the TOP-LEFT.
// This is the one conversion between the two. If you ever change orientation, change it here.

/// Upright Vision point (origin bottom-left) → normalised sensor-native point (origin top-left).
@inline(__always)
func uprightToNative(_ p: CGPoint) -> CGPoint {
    CGPoint(x: 1 - p.y, y: 1 - p.x)
}

// MARK: - Skeleton (2D joints in upright coordinates)

struct Skeleton {
    typealias Joint = VNHumanBodyPoseObservation.JointName

    private(set) var points: [Joint: CGPoint] = [:]
    private(set) var confidences: [Joint: Float] = [:]

    init(observation: VNHumanBodyPoseObservation, minConfidence: Float) {
        guard let all = try? observation.recognizedPoints(.all) else { return }
        for (name, point) in all {
            confidences[name] = point.confidence
            if point.confidence >= minConfidence { points[name] = point.location }
        }
    }

    subscript(_ joint: Joint) -> CGPoint? { points[joint] }

    /// Midpoint of a left/right pair, or whichever side is visible (side-on poses hide one side).
    func pair(_ a: Joint, _ b: Joint) -> CGPoint? {
        switch (points[a], points[b]) {
        case let (p?, q?): return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
        case let (p?, nil): return p
        case let (nil, q?): return q
        default: return nil
        }
    }

    var shoulderCenter: CGPoint? { pair(.leftShoulder, .rightShoulder) }
    var hipCenter: CGPoint? { pair(.leftHip, .rightHip) ?? points[.root] }

    /// Horizontal shoulder span relative to torso length. ~0.6+ facing the camera, ~0.1 side-on.
    var shoulderToTorsoRatio: CGFloat? {
        guard let l = points[.leftShoulder], let r = points[.rightShoulder],
              let s = shoulderCenter, let h = hipCenter else { return nil }
        let torso = hypot(s.x - h.x, s.y - h.y)
        guard torso > 0 else { return nil }
        return abs(l.x - r.x) / torso
    }
}

// MARK: - Depth map

/// A CPU copy of one Float32 depth map plus the lens intrinsics scaled to its resolution.
struct DepthMap {
    let width: Int
    let height: Int
    let values: [Float]
    /// Focal lengths in depth-map pixels.
    let fx: Float
    let fy: Float

    init?(depthData: AVDepthData, sampleBuffer: CMSampleBuffer) {
        let buffer = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var copy = [Float](repeating: .nan, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { copy[y * w + x] = row[x] }
        }

        // Intrinsics: prefer the depth calibration data; fall back to the per-frame matrix on the colour frame.
        let matrix: matrix_float3x3
        let referenceWidth: Float
        if let calibration = depthData.cameraCalibrationData {
            matrix = calibration.intrinsicMatrix
            referenceWidth = Float(calibration.intrinsicMatrixReferenceDimensions.width)
        } else if let data = CMGetAttachment(sampleBuffer,
                                             key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                             attachmentModeOut: nil) as? Data,
                  let image = CMSampleBufferGetImageBuffer(sampleBuffer) {
            matrix = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
            referenceWidth = Float(CVPixelBufferGetWidth(image))
        } else {
            return nil
        }
        guard referenceWidth > 0 else { return nil }
        let scale = Float(w) / referenceWidth

        width = w
        height = h
        values = copy
        fx = matrix.columns.0.x * scale
        fy = matrix.columns.1.y * scale
    }

    func depth(x: Int, y: Int) -> Float? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let d = values[y * width + x]
        return d.isFinite && d > 0 ? d : nil
    }

    func median(x: Int, y: Int, radius: Int = 2) -> Float? {
        var samples: [Float] = []
        for dy in -radius...radius { for dx in -radius...radius {
            if let d = depth(x: x + dx, y: y + dy) { samples.append(d) }
        } }
        return samples.median
    }

    func pixel(forUpright p: CGPoint) -> (x: Int, y: Int) {
        let n = uprightToNative(p)
        return (Int((n.x * CGFloat(width)).rounded()), Int((n.y * CGFloat(height)).rounded()))
    }

    /// Distance (m) from the lens to the body at an upright image point.
    func distance(atUpright p: CGPoint) -> Float? {
        let px = pixel(forUpright: p)
        return median(x: px.x, y: px.y, radius: 3)
    }

    /// Real-world width (m) of the body along the upright HORIZONTAL line through `p`.
    ///
    /// An upright horizontal line is a single native COLUMN, so we walk up and down that column from
    /// the body centre until depth jumps to the background. Pixels are converted to metres with the
    /// pinhole model (metres = pixels × depth / focal length) using the depth at the silhouette edges,
    /// which sit near the body's mid-plane. Several neighbouring columns are measured and the median kept.
    func bodyWidth(atUpright p: CGPoint, backgroundGap: Float = 0.35, columns: Int = 2) -> Float? {
        let centre = pixel(forUpright: p)
        var widths: [Float] = []
        for dc in -columns...columns {
            if let w = span(column: centre.x + dc, centreRow: centre.y, backgroundGap: backgroundGap) {
                widths.append(w)
            }
        }
        guard widths.count > columns else { return nil } // need a majority of columns to agree
        return widths.median
    }

    private func span(column: Int, centreRow: Int, backgroundGap: Float) -> Float? {
        guard column >= 0, column < width, let zCentre = median(x: column, y: centreRow, radius: 1) else { return nil }
        let limit = zCentre + backgroundGap
        func isBody(_ row: Int) -> Bool { depth(x: column, y: row).map { $0 < limit } ?? false }

        var top = centreRow, bottom = centreRow
        while top - 1 >= 0, isBody(top - 1) { top -= 1 }
        while bottom + 1 < height, isBody(bottom + 1) { bottom += 1 }
        // Touching the frame edge means the body is cut off: the width is unknowable.
        guard top > 0, bottom < height - 1, bottom - top >= 4 else { return nil }

        let edgeDepths = [top + 1, top + 2, bottom - 1, bottom - 2].compactMap { depth(x: column, y: $0) }
        guard let zEdge = edgeDepths.median else { return nil }
        let pixels = Float(bottom - top + 1)
        return pixels * zEdge / fy
    }
}

// MARK: - Body landmarks & per-frame measurement

/// Raw measurements from one accepted frame, in metres.
struct FrameMeasurement {
    var height: Float?
    var neck: Float?
    var chest: Float?
    var waist: Float?
    var hip: Float?
}

enum BodyGeometry {
    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Anatomical measurement lines derived from the skeleton (upright coordinates, y points UP).
    static func landmarks(_ s: Skeleton) -> (neck: CGPoint?, chest: CGPoint?, waist: CGPoint?, hip: CGPoint?) {
        guard let shoulders = s.shoulderCenter, let hips = s.hipCenter else { return (nil, nil, nil, nil) }
        let torso = hypot(shoulders.x - hips.x, shoulders.y - hips.y)
        let neck: CGPoint? = {
            guard let base = s[.neck], let nose = s[.nose] else { return nil }
            return lerp(base, nose, 0.35)
        }()
        let chest = lerp(shoulders, hips, 0.30)                    // armpit / nipple line
        let waist = lerp(shoulders, hips, 0.70)                    // natural waist, above the hip joints
        let hip = CGPoint(x: hips.x, y: hips.y - torso * 0.12)     // widest point of the seat, below the hip joints
        return (neck, chest, waist, hip)
    }

    static func measure(skeleton: Skeleton, depth: DepthMap, bodyHeight: Float?) -> FrameMeasurement {
        let lm = landmarks(skeleton)
        return FrameMeasurement(
            height: bodyHeight,
            neck: lm.neck.flatMap { depth.bodyWidth(atUpright: $0) },
            chest: lm.chest.flatMap { depth.bodyWidth(atUpright: $0) },
            waist: lm.waist.flatMap { depth.bodyWidth(atUpright: $0) },
            hip: lm.hip.flatMap { depth.bodyWidth(atUpright: $0) }
        )
    }

    /// Ramanujan's ellipse perimeter from a front width and a side depth (both full diameters).
    static func circumference(width: Float, depth: Float) -> Float {
        let a = width / 2, b = depth / 2
        return .pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot())
    }
}

// MARK: - Robust statistics

struct RobustEstimate {
    let value: Float
    /// Frame-to-frame spread (1σ, from the median absolute deviation). This is repeatability, NOT total error.
    let spread: Float
    let samples: Int
}

extension Array where Element == Float {
    var median: Float? {
        guard !isEmpty else { return nil }
        let s = sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Median with outliers (> 3σ) discarded, so one bad frame can't skew the result.
    var robustEstimate: RobustEstimate? {
        guard let m = median else { return nil }
        let mad = (map { abs($0 - m) }.median ?? 0) * 1.4826
        let kept = mad > 0 ? filter { abs($0 - m) <= 3 * mad } : self
        guard let value = kept.median else { return nil }
        return RobustEstimate(value: value, spread: mad, samples: kept.count)
    }
}
