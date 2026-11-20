import AVFoundation
import CoreMotion
import simd

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
