import AVFoundation
import Combine
import Vision

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
