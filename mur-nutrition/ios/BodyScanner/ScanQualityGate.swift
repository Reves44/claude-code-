import CoreVideo
import Vision

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
