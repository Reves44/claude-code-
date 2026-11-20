import AVFoundation
import Combine
import CoreMotion
import SwiftUI
import Vision
import simd

// MUR Nutrition Body Scanner: paste this whole file into your Xcode project as BodyScanner.swift
// Show it with: BodyScanView()

// MARK: ===== BodyScanCamera.swift =====

// MARK: - Camera

enum BodyScanCameraError: LocalizedError {
    case noDepthCamera
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDepthCamera:
            return "This iPhone has no rear depth camera. Body scanning needs a LiDAR (Pro) or dual rear camera."
        case .configurationFailed(let reason):
            return "Camera setup failed: \(reason)"
        }
    }
}

/// One synchronized colour + depth frame straight from the sensor (landscape, sensor-native orientation).
struct CameraFrame {
    let sampleBuffer: CMSampleBuffer
    let pixelBuffer: CVPixelBuffer
    /// Always converted to `kCVPixelFormatType_DepthFloat32` (metres).
    let depthData: AVDepthData
}

/// Configures the rear camera for measurement-grade capture:
/// - prefers the LiDAR depth camera, then dual cameras
/// - picks the format with the highest-resolution depth map
/// - turns video stabilisation OFF (it crops and warps frames, which breaks the lens intrinsics we measure with)
/// - delivers colour and depth frames that are synchronized to the same instant
final class BodyScanCamera: NSObject, AVCaptureDataOutputSynchronizerDelegate {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private let sessionQueue = DispatchQueue(label: "mur.bodyscan.session")
    /// Every frame callback and all frame processing happens on this queue.
    let dataQueue = DispatchQueue(label: "mur.bodyscan.data", qos: .userInitiated)

    private(set) var device: AVCaptureDevice?
    private(set) var isLiDAR = false

    /// Called on `dataQueue` for every synchronized frame.
    var onFrame: ((CameraFrame) -> Void)?

    func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority // we choose the format ourselves below

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInDualCamera],
            mediaType: .video,
            position: .back
        )
        guard let device = discovery.devices.first else { throw BodyScanCameraError.noDepthCamera }
        self.device = device
        isLiDAR = device.deviceType == .builtInLiDARDepthCamera

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw BodyScanCameraError.configurationFailed("cannot add camera input") }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { throw BodyScanCameraError.configurationFailed("cannot add video output") }
        session.addOutput(videoOutput)

        depthOutput.isFilteringEnabled = true // fills small holes in the depth map
        depthOutput.alwaysDiscardsLateDepthData = true
        guard session.canAddOutput(depthOutput) else { throw BodyScanCameraError.configurationFailed("cannot add depth output") }
        session.addOutput(depthOutput)

        try device.lockForConfiguration()
        guard let format = Self.bestFormat(for: device),
              let depthFormat = Self.bestDepthFormat(for: format) else {
            device.unlockForConfiguration()
            throw BodyScanCameraError.configurationFailed("no format with depth support")
        }
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        device.unlockForConfiguration()

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled = true }
        }
        depthOutput.connection(with: .depthData)?.isEnabled = true

        let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        sync.setDelegate(self, queue: dataQueue)
        synchronizer = sync
    }

    func start() { sessionQueue.async { [session] in if !session.isRunning { session.startRunning() } } }
    func stop() { sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } } }

    /// Format with the highest-resolution depth map; ties broken by colour resolution (capped at 12 MP).
    private static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats
            .filter { format in
                CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    && bestDepthFormat(for: format) != nil
                    && CMVideoFormatDescriptionGetDimensions(format.formatDescription).width <= 4032
            }
            .max { a, b in
                let da = depthWidth(bestDepthFormat(for: a)), db = depthWidth(bestDepthFormat(for: b))
                if da != db { return da < db }
                return CMVideoFormatDescriptionGetDimensions(a.formatDescription).width
                    < CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
            }
    }

    private static func bestDepthFormat(for format: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
        format.supportedDepthDataFormats
            .filter { CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32 }
            .max { depthWidth($0) < depthWidth($1) }
    }

    private static func depthWidth(_ format: AVCaptureDevice.Format?) -> Int32 {
        guard let format else { return 0 }
        return CMVideoFormatDescriptionGetDimensions(format.formatDescription).width
    }

    // MARK: AVCaptureDataOutputSynchronizerDelegate

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard let syncedDepth = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !syncedDepth.depthDataWasDropped,
              let syncedVideo = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideo.sampleBufferWasDropped,
              let pixelBuffer = CMSampleBufferGetImageBuffer(syncedVideo.sampleBuffer)
        else { return }

        // Dual cameras deliver disparity; LiDAR delivers depth. Normalise both to metres.
        let raw = syncedDepth.depthData
        let depth = raw.depthDataType == kCVPixelFormatType_DepthFloat32
            ? raw
            : raw.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)

        onFrame?(CameraFrame(sampleBuffer: syncedVideo.sampleBuffer, pixelBuffer: pixelBuffer, depthData: depth))
    }
}

// MARK: - Motion

struct MotionSnapshot {
    /// Gravity in device coordinates (unit g). Upright portrait ≈ (0, -1, 0).
    var gravity = simd_double3(0, -1, 0)
    /// Rotation rate magnitude in rad/s.
    var rotationRate: Double = 0
    var isAvailable = false
}

/// Tracks whether the phone is held level and still. Readable from any thread.
final class MotionMonitor {
    private let manager = CMMotionManager()
    private let lock = NSLock()
    private var latest = MotionSnapshot()

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let g = motion.gravity, r = motion.rotationRate
            let snapshot = MotionSnapshot(
                gravity: simd_double3(g.x, g.y, g.z),
                rotationRate: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot(),
                isAvailable: true
            )
            self.lock.lock(); self.latest = snapshot; self.lock.unlock()
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    var snapshot: MotionSnapshot {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}

// MARK: ===== BodyGeometry.swift =====

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

// MARK: ===== ScanQualityGate.swift =====

enum ScanPose { case front, side }

/// Everything that can make a frame unfit to measure. A frame is used only when there are NO issues.
enum ScanIssue: Hashable {
    case noPerson
    case multiplePeople
    case bodyNotFullyVisible
    case tooClose
    case tooFar
    case holdPhoneUpright
    case phoneMoving
    case personMoving
    case tooDark
    case tooBright
    case raiseArms
    case faceCamera
    case turnSideways
    case noDepth

    var instruction: String {
        switch self {
        case .noPerson: return "Step into the frame"
        case .multiplePeople: return "Only one person in the frame"
        case .bodyNotFullyVisible: return "Show your whole body, head to feet"
        case .tooClose: return "Step back"
        case .tooFar: return "Step closer"
        case .holdPhoneUpright: return "Hold the phone straight up, at waist height"
        case .phoneMoving: return "Hold the phone still (or prop it up)"
        case .personMoving: return "Stand still"
        case .tooDark: return "Turn on more lights"
        case .tooBright: return "Too much light behind you, change position"
        case .raiseArms: return "Hold your arms slightly away from your body"
        case .faceCamera: return "Face the camera"
        case .turnSideways: return "Turn to your side"
        case .noDepth: return "Depth not available, move to a less reflective spot"
        }
    }
}

struct ScanQualityConfig {
    var minJointConfidence: Float = 0.6
    /// Joints must sit at least this far inside the image edge (normalised).
    var frameMargin: CGFloat = 0.03
    /// LiDAR is most accurate around 1.5–3 m; closer and the whole body doesn't fit.
    var minDistance: Float = 1.5
    var maxDistance: Float = 3.2
    /// Max tilt of the phone away from vertical, in units of g (0.07 ≈ 4°).
    var maxTilt: Double = 0.07
    var maxRotationRate: Double = 0.08
    /// Max joint movement between consecutive frames (normalised image units).
    var maxJointDrift: CGFloat = 0.008
    var lumaRange: ClosedRange<Float> = 55...215
}

/// Rejects every frame that would produce a bad measurement. This is the main accuracy lever:
/// it is far better to measure 30 perfect frames than 300 mediocre ones.
struct ScanQualityGate {
    var config = ScanQualityConfig()
    private var previous: [Skeleton.Joint: CGPoint] = [:]

    private static let frontRequired: [Skeleton.Joint] = [
        .nose, .neck, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist,
        .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
    ]
    private static let sidePairs: [(Skeleton.Joint, Skeleton.Joint)] = [
        (.leftShoulder, .rightShoulder), (.leftHip, .rightHip), (.leftKnee, .rightKnee), (.leftAnkle, .rightAnkle),
    ]

    mutating func reset() { previous = [:] }

    mutating func evaluate(skeleton: Skeleton,
                           peopleCount: Int,
                           pose: ScanPose,
                           distance: Float?,
                           luma: Float,
                           motion: MotionSnapshot) -> [ScanIssue] {
        var issues: [ScanIssue] = []
        if peopleCount > 1 { issues.append(.multiplePeople) }

        // Phone orientation and stillness
        if motion.isAvailable {
            if abs(motion.gravity.x) > config.maxTilt || abs(motion.gravity.z) > config.maxTilt {
                issues.append(.holdPhoneUpright)
            }
            if motion.rotationRate > config.maxRotationRate { issues.append(.phoneMoving) }
        }

        // Lighting
        if luma < config.lumaRange.lowerBound { issues.append(.tooDark) }
        if luma > config.lumaRange.upperBound { issues.append(.tooBright) }

        // Whole body visible with confident joints
        let visible: Bool
        switch pose {
        case .front:
            visible = Self.frontRequired.allSatisfy { skeleton[$0] != nil }
        case .side:
            visible = skeleton[.nose] != nil && Self.sidePairs.allSatisfy { skeleton.pair($0.0, $0.1) != nil }
        }
        let m = config.frameMargin
        let insideFrame = skeleton.points.values.allSatisfy { $0.x > m && $0.x < 1 - m && $0.y > m && $0.y < 1 - m }
        if !visible || !insideFrame { issues.append(.bodyNotFullyVisible) }

        // Distance
        if let distance {
            if distance < config.minDistance { issues.append(.tooClose) }
            if distance > config.maxDistance { issues.append(.tooFar) }
        } else {
            issues.append(.noDepth)
        }

        // Pose
        if let ratio = skeleton.shoulderToTorsoRatio {
            switch pose {
            case .front where ratio < 0.45: issues.append(.faceCamera)
            case .side where ratio > 0.22: issues.append(.turnSideways)
            default: break
            }
        }
        if pose == .front, !armsAwayFromTorso(skeleton) { issues.append(.raiseArms) }

        // Subject stillness
        if !previous.isEmpty {
            let drifts = skeleton.points.compactMap { name, p in previous[name].map { hypot(p.x - $0.x, p.y - $0.y) } }
            if let worst = drifts.max(), worst > config.maxJointDrift { issues.append(.personMoving) }
        }
        previous = skeleton.points

        return issues
    }

    /// Arms must clear the waist/hip line, otherwise they get measured as part of the torso.
    private func armsAwayFromTorso(_ s: Skeleton) -> Bool {
        guard let lw = s[.leftWrist], let rw = s[.rightWrist], let lh = s[.leftHip], let rh = s[.rightHip],
              let ls = s[.leftShoulder], let rs = s[.rightShoulder] else { return false }
        let centreX = (lh.x + rh.x) / 2
        let clearance = abs(ls.x - rs.x) * 0.15
        return abs(lw.x - centreX) > abs(lh.x - centreX) + clearance
            && abs(rw.x - centreX) > abs(rh.x - centreX) + clearance
    }
}

enum ImageStats {
    /// Mean brightness (0–255) of the luma plane, sampled on a sparse grid.
    static func meanLuma(_ buffer: CVPixelBuffer, step: Int = 16) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, count = 0
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) { sum += Int(bytes[y * rowBytes + x]); count += 1 }
        }
        return count > 0 ? Float(sum) / Float(count) : 0
    }
}

// MARK: ===== BodyScanSession.swift =====

// MARK: - Inputs & outputs

enum BiologicalSex: String, CaseIterable, Identifiable {
    case male, female
    var id: String { rawValue }
}

struct BodyScanProfile {
    /// The user's tape-measured height. Strongly recommended: it is used to correct the overall scale.
    var knownHeightCm: Float?
    var sex: BiologicalSex = .male
}

/// Per-measurement correction factors found by validating the scanner against a tape measure
/// (see README). Leave at 1.0 until you have validation data.
struct ScanCalibration {
    var neck: Float = 1.0
    var chest: Float = 1.0
    var waist: Float = 1.0
    var hip: Float = 1.0
}

struct BodyMeasurement {
    let cm: Float
    /// ± cm, 1σ frame-to-frame repeatability. Real error vs a tape measure is larger; validate it.
    let spreadCm: Float
}

struct BodyScanResult {
    let height: BodyMeasurement
    let neck: BodyMeasurement?
    let chest: BodyMeasurement?
    let waist: BodyMeasurement?
    let hip: BodyMeasurement?
    /// U.S. Navy circumference method. Published error is roughly ±3–4 % body fat even with a perfect tape.
    let bodyFatPercent: Float?
    let heightScaleApplied: Float
    let framesUsed: Int
    let usedLiDAR: Bool
}

// MARK: - Frame processor (runs only on the camera's data queue)

private final class FrameProcessor {
    struct Update {
        var stage: BodyScanSession.Stage
        var issues: [ScanIssue]
        var progress: Double
        var result: BodyScanResult?
    }

    var framesPerPose = 30
    var profile = BodyScanProfile()
    var calibration = ScanCalibration()
    var usedLiDAR = false

    private(set) var stage: BodyScanSession.Stage = .idle
    private var gate = ScanQualityGate()
    private var front: [FrameMeasurement] = []
    private var side: [FrameMeasurement] = []

    func begin() {
        front.removeAll(); side.removeAll(); gate.reset()
        stage = .front
    }

    func cancel() { stage = .idle }

    func process(_ frame: CameraFrame, motion: MotionSnapshot) -> Update? {
        let pose: ScanPose
        switch stage {
        case .front: pose = .front
        case .side: pose = .side
        default: return nil
        }

        let luma = ImageStats.meanLuma(frame.pixelBuffer)
        let pose2D = VNDetectHumanBodyPoseRequest()
        let pose3D = VNDetectHumanBodyPose3DRequest()
        // Giving Vision the depth map lets the 3D request MEASURE height instead of assuming 1.8 m.
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer,
                                            depthData: frame.depthData,
                                            orientation: .right,
                                            options: [:])
        do { try handler.perform([pose2D, pose3D]) } catch { return update([.noPerson]) }

        guard let body = pose2D.results?.first else { return update([.noPerson]) }
        let skeleton = Skeleton(observation: body, minConfidence: gate.config.minJointConfidence)
        guard let depth = DepthMap(depthData: frame.depthData, sampleBuffer: frame.sampleBuffer) else {
            return update([.noDepth])
        }
        let distance = skeleton.hipCenter.flatMap { depth.distance(atUpright: $0) }

        var issues = gate.evaluate(skeleton: skeleton,
                                   peopleCount: pose2D.results?.count ?? 0,
                                   pose: pose,
                                   distance: distance,
                                   luma: luma,
                                   motion: motion)
        let body3D = pose3D.results?.first
        if issues.isEmpty, body3D?.heightEstimation != .measured { issues.append(.noDepth) }
        guard issues.isEmpty else { return update(issues) }

        let m = BodyGeometry.measure(skeleton: skeleton, depth: depth, bodyHeight: body3D?.bodyHeight)
        switch pose {
        case .front:
            front.append(m)
            if front.count >= framesPerPose { stage = .side; gate.reset() }
        case .side:
            side.append(m)
            if side.count >= framesPerPose {
                stage = .finished
                return Update(stage: .finished, issues: [], progress: 1, result: makeResult())
            }
        }
        return update([])
    }

    private func update(_ issues: [ScanIssue]) -> Update {
        let done = Double(front.count + side.count)
        return Update(stage: stage, issues: issues, progress: done / Double(framesPerPose * 2), result: nil)
    }

    private func makeResult() -> BodyScanResult? {
        let heights = (front + side).compactMap(\.height)
        guard let height = heights.robustEstimate else { return nil }

        // Overall scale correction from the user's known height.
        var scale: Float = 1
        if let known = profile.knownHeightCm, known > 0 {
            let ratio = (known / 100) / height.value
            if (0.85...1.15).contains(ratio) { scale = ratio } // outside ±15 % the scan itself is suspect
        }

        func circumference(_ key: KeyPath<FrameMeasurement, Float?>, factor: Float) -> BodyMeasurement? {
            // Require that most frames produced a value; otherwise the line was unreliable.
            let w = front.compactMap { $0[keyPath: key] }, d = side.compactMap { $0[keyPath: key] }
            guard w.count * 10 >= front.count * 6, d.count * 10 >= side.count * 6,
                  let width = w.robustEstimate, let depth = d.robustEstimate else { return nil }
            let c = BodyGeometry.circumference(width: width.value, depth: depth.value)
            // dC ≈ (π/2)(dw + dd) for an ellipse; combine the two spreads in quadrature.
            let spread = Float.pi / 2 * (width.spread * width.spread + depth.spread * depth.spread).squareRoot()
            return BodyMeasurement(cm: c * scale * factor * 100, spreadCm: spread * scale * factor * 100)
        }

        let neck = circumference(\.neck, factor: calibration.neck)
        let chest = circumference(\.chest, factor: calibration.chest)
        let waist = circumference(\.waist, factor: calibration.waist)
        let hip = circumference(\.hip, factor: calibration.hip)
        let heightCm = profile.knownHeightCm ?? height.value * 100

        return BodyScanResult(
            height: BodyMeasurement(cm: heightCm, spreadCm: height.spread * 100),
            neck: neck, chest: chest, waist: waist, hip: hip,
            bodyFatPercent: Self.navyBodyFat(sex: profile.sex, heightCm: heightCm,
                                             neckCm: neck?.cm, waistCm: waist?.cm, hipCm: hip?.cm),
            heightScaleApplied: scale,
            framesUsed: front.count + side.count,
            usedLiDAR: usedLiDAR
        )
    }

    /// U.S. Navy body-fat equations (metric form).
    static func navyBodyFat(sex: BiologicalSex, heightCm: Float, neckCm: Float?, waistCm: Float?, hipCm: Float?) -> Float? {
        guard let neck = neckCm, let waist = waistCm else { return nil }
        let value: Float
        switch sex {
        case .male:
            guard waist > neck else { return nil }
            value = 495 / (1.0324 - 0.19077 * log10(waist - neck) + 0.15456 * log10(heightCm)) - 450
        case .female:
            guard let hip = hipCm, waist + hip > neck else { return nil }
            value = 495 / (1.29579 - 0.35004 * log10(waist + hip - neck) + 0.22100 * log10(heightCm)) - 450
        }
        return (2...60).contains(value) ? value : nil
    }
}

// MARK: - Session (UI-facing)

@MainActor
final class BodyScanSession: ObservableObject {
    enum Stage: Equatable { case idle, front, side, finished, failed(String) }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var issues: [ScanIssue] = []
    @Published private(set) var progress: Double = 0
    @Published private(set) var result: BodyScanResult?

    let camera = BodyScanCamera()
    private let motion = MotionMonitor()
    private let processor = FrameProcessor()
    private var configured = false

    /// Set up the camera and show the live preview. Call once when the scan screen appears.
    func prepare() {
        guard !configured else { camera.start(); return }
        do {
            try camera.configure()
            configured = true
        } catch {
            stage = .failed(error.localizedDescription)
            return
        }
        let processor = self.processor, motion = self.motion
        processor.usedLiDAR = camera.isLiDAR
        camera.onFrame = { [weak self] frame in
            guard let update = processor.process(frame, motion: motion.snapshot) else { return }
            Task { @MainActor in self?.apply(update) }
        }
        motion.start()
        camera.start()
    }

    func startScan(profile: BodyScanProfile, calibration: ScanCalibration = ScanCalibration()) {
        result = nil; progress = 0; issues = []; stage = .front
        camera.dataQueue.async { [processor] in
            processor.profile = profile
            processor.calibration = calibration
            processor.begin()
        }
    }

    func cancel() {
        stage = .idle
        result = nil
        camera.dataQueue.async { [processor] in processor.cancel() }
    }

    func shutdown() {
        camera.stop()
        motion.stop()
    }

    private func apply(_ update: FrameProcessor.Update) {
        guard stage == .front || stage == .side else { return } // ignore late frames after cancel/finish
        issues = update.issues
        progress = update.progress
        if update.stage == .finished {
            if let result = update.result {
                self.result = result
                stage = .finished
            } else {
                stage = .failed("The scan couldn't produce reliable measurements. Try again with better lighting.")
            }
        } else {
            stage = update.stage
        }
    }
}

// MARK: ===== BodyScanView.swift =====

/// Full-screen body scan: live camera, live coaching, then results.
struct BodyScanView: View {
    @StateObject private var scan = BodyScanSession()
    @State private var heightText = ""
    @State private var sex: BiologicalSex = .male

    private let accent = Color(red: 0.36, green: 0.88, blue: 0.66) // MUR green #5be0a8

    var body: some View {
        ZStack {
            CameraPreview(session: scan.camera.session).ignoresSafeArea()
            VStack {
                header
                Spacer()
                footer
            }
            .padding()
        }
        .background(Color.black)
        .onAppear { scan.prepare() }
        .onDisappear { scan.shutdown() }
        .sheet(isPresented: .constant(scan.result != nil)) {
            if let result = scan.result {
                ResultView(result: result) { scan.cancel() }.interactiveDismissDisabled()
            }
        }
    }

    @ViewBuilder private var header: some View {
        switch scan.stage {
        case .front, .side:
            VStack(spacing: 8) {
                Text(scan.stage == .front ? "Step 1 of 2 · Face the camera, arms slightly out"
                                          : "Step 2 of 2 · Turn to your side")
                    .font(.headline)
                ProgressView(value: scan.progress).tint(accent)
                if let issue = scan.issues.first {
                    Text(issue.instruction).font(.title3.bold()).foregroundStyle(.yellow)
                } else {
                    Text("Hold still…").font(.title3.bold()).foregroundStyle(accent)
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .failed(let message):
            Text(message).padding().background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var footer: some View {
        if scan.stage == .front || scan.stage == .side {
            Button("Cancel") { scan.cancel() }.buttonStyle(.bordered)
        } else {
            VStack(spacing: 12) {
                Text("Prop your phone upright at waist height, 2–2.5 m away. Wear fitted clothing and stand at least 1 m in front of a plain wall.")
                    .font(.footnote).multilineTextAlignment(.center)
                TextField("Your height (cm), measured with a tape", text: $heightText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Picker("Sex", selection: $sex) {
                    ForEach(BiologicalSex.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Button {
                    scan.startScan(profile: BodyScanProfile(knownHeightCm: Float(heightText), sex: sex))
                } label: {
                    Text("Start body scan").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct ResultView: View {
    let result: BodyScanResult
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Measurements") {
                    row("Height", result.height)
                    row("Neck", result.neck)
                    row("Chest", result.chest)
                    row("Waist", result.waist)
                    row("Hips", result.hip)
                }
                if let bf = result.bodyFatPercent {
                    Section("Estimated body fat") {
                        Text(String(format: "%.1f %%", bf)).font(.title2.bold())
                        Text("U.S. Navy method. Typical error is about ±3–4 %.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("\(result.framesUsed) frames · \(result.usedLiDAR ? "LiDAR" : "dual camera") depth")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Body scan")
            .toolbar { Button("Done", action: onDone) }
        }
    }

    @ViewBuilder private func row(_ label: String, _ m: BodyMeasurement?) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let m {
                Text(String(format: "%.1f cm", m.cm)).bold()
                Text(String(format: "±%.1f", m.spreadCm)).foregroundStyle(.secondary)
            } else {
                Text("not reliable, rescan").foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows the whole sensor frame (aspect-fit) so the user sees exactly what is being measured.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
