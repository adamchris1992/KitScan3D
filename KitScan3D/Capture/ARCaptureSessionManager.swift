import Foundation
import ARKit
import AVFoundation
import Combine
import simd

struct CameraHardwareBounds: Equatable {
    var minISO: Float = 50
    var maxISO: Float = 1600
    var minExposureSeconds: Double = 1.0 / 2000.0
    var maxExposureSeconds: Double = 1.0 / 15.0
    var minExposureBias: Float = -2.0
    var maxExposureBias: Float = 2.0
}

struct TrackingRecoveryStatus: Equatable {
    var stateTitle: String = "Initializing"
    var guidanceMessage: String? = "Move your iPhone slowly to initialize tracking."
    var isHealthy: Bool = false
}

/// Manages ARSession, LiDAR depth, FHD/4K format selection, AutoMagic/manual exposure & WB, and Scan & Go triggers.
final class ARCaptureSessionManager: NSObject, ObservableObject {
    let session = ARSession()

    @Published var settings = CaptureSettings()
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var capturedFrameCount = 0
    @Published private(set) var trackingStatus = TrackingRecoveryStatus()
    @Published private(set) var hardwareBounds = CameraHardwareBounds()
    @Published private(set) var availableResolutions: [ResolutionPreset] = []
    @Published private(set) var trajectoryPoses: [simd_float4x4] = []
    @Published private(set) var currentCameraPose: simd_float4x4 = matrix_identity_float4x4
    /// Non-nil while a pass is active (recording or paused). Cleared by `finishRecording()`.
    @Published private(set) var currentScan: ScanSessionMetadata?

    var onFrameUpdate: ((ARFrame) -> Void)?
    var onKeyframeCaptured: ((ARFrame) -> Void)?

    private var activeProjectID: UUID?
    private var lastKeyframeTime: TimeInterval = 0
    private var lastKeyframePose: simd_float4x4?
    private var pendingManualShot = false
    private let logger = DiagnosticsLogger.shared

    static var isLiDARSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    override init() {
        super.init()
        session.delegate = self
        detectSupportedVideoFormats()
    }

    // MARK: - Session

    func startSession() {
        guard Self.isLiDARSupported else {
            logger.log(.error, category: "ARKit", "Device does not support LiDAR sceneDepth.")
            trackingStatus = TrackingRecoveryStatus(
                stateTitle: "Unsupported Hardware",
                guidanceMessage: "LiDAR sensor (iPhone Pro / iPad Pro) is required.",
                isHealthy: false
            )
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = []
        config.worldAlignment = .gravity
        config.frameSemantics.insert(.sceneDepth)
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }

        if let format = bestVideoFormat(for: settings.resolution) {
            config.videoFormat = format
            logger.log(.info, category: "ARKit", "Video format: \(Int(format.imageResolution.width))x\(Int(format.imageResolution.height)) @ \(format.framesPerSecond)fps")
        }

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
        refreshHardwareBounds()

        // Give auto-exposure a moment to meter before locking or applying manual values
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if self.settings.useManualControls {
                self.applyManualCameraControls()
            } else if self.settings.isAutoMagicLocked {
                self.lockAutoMagicExposureAndWhiteBalance()
            }
        }
    }

    /// Stops the camera. Any active pass is finalized and saved.
    func pauseSession() {
        finishRecording()
        session.pause()
        isSessionRunning = false
        logger.log(.info, category: "ARKit", "ARSession paused")
    }

    func applyResolution(_ preset: ResolutionPreset) {
        settings.resolution = preset
        if isSessionRunning {
            startSession()
        }
    }

    /// Actual camera image size ARKit will deliver for a preset (e.g. 1920x1440, 3840x2880).
    func dimensions(for preset: ResolutionPreset) -> CGSize? {
        bestVideoFormat(for: preset)?.imageResolution
    }

    // MARK: - Recording (start / pause / resume / finish)

    /// Starts a new pass, or resumes the current paused pass.
    func startRecording(in projectID: UUID) {
        guard isSessionRunning, !isRecording else { return }

        if currentScan == nil {
            let size = dimensions(for: settings.resolution) ?? CGSize(width: 1920, height: 1440)
            guard let scan = ScanProjectStore.shared.beginNewScanSession(
                projectID: projectID,
                width: Int(size.width),
                height: Int(size.height)
            ) else { return }

            activeProjectID = projectID
            currentScan = scan
            capturedFrameCount = 0
            trajectoryPoses.removeAll()
            logger.log(.info, category: "Capture", "Recording started (\(settings.captureMode.rawValue), \(settings.resolution.rawValue))")
        } else {
            logger.log(.info, category: "Capture", "Recording resumed at keyframe \(capturedFrameCount)")
        }

        lastKeyframeTime = 0
        lastKeyframePose = nil
        isRecording = true

        if settings.isAutoMagicLocked && !settings.useManualControls {
            lockAutoMagicExposureAndWhiteBalance()
        }
    }

    func pauseRecording() {
        guard isRecording else { return }
        isRecording = false
        saveCurrentScanStats()
        logger.log(.info, category: "Capture", "Recording paused. Keyframes so far: \(capturedFrameCount)")
    }

    /// Ends the active pass. Empty passes are discarded.
    func finishRecording() {
        isRecording = false
        guard let projectID = activeProjectID, let scan = currentScan else { return }

        if capturedFrameCount == 0 {
            ScanProjectStore.shared.deleteScan(projectID: projectID, scanID: scan.id)
            logger.log(.info, category: "Capture", "Discarded empty pass")
        } else {
            saveCurrentScanStats()
            logger.log(.info, category: "Capture", "Recording finished. Total keyframes: \(capturedFrameCount)")
        }
        currentScan = nil
        activeProjectID = nil
    }

    func triggerManualShot() {
        guard isRecording else { return }
        pendingManualShot = true
    }

    private func saveCurrentScanStats() {
        guard let projectID = activeProjectID, var scan = currentScan else { return }
        scan.frameCount = capturedFrameCount
        ScanProjectStore.shared.updateScanStats(projectID: projectID, scan: scan)
        currentScan = scan
    }

    // MARK: - Exposure & White Balance

    /// Locks current exposure & white balance so every frame in the scan matches.
    func lockAutoMagicExposureAndWhiteBalance() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            logger.log(.warning, category: "Camera", "configurableCaptureDeviceForPrimaryCamera unavailable")
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }

            settings.isAutoMagicLocked = true
            settings.useManualControls = false
            settings.manualISO = device.iso
            settings.manualExposureDurationSeconds = CMTimeGetSeconds(device.exposureDuration)
            settings.exposureBias = device.exposureTargetBias

            let tempTint = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
            settings.whiteBalanceKelvin = max(2000, min(8000, tempTint.temperature))

            logger.log(.info, category: "Camera", String(format: "AutoMagic locked: ISO %.0f, 1/%.0fs, %.0fK", settings.manualISO, 1.0 / max(0.0001, settings.manualExposureDurationSeconds), settings.whiteBalanceKelvin))
        } catch {
            logger.log(.error, category: "Camera", "Failed to lock AutoMagic: \(error.localizedDescription)")
        }
    }

    /// Briefly returns to auto exposure/WB to re-meter the scene, then re-locks.
    func unlockAndRemeterAutoMagic() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
            settings.isAutoMagicLocked = false
            settings.useManualControls = false
            logger.log(.info, category: "Camera", "Re-metering exposure & white balance...")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.lockAutoMagicExposureAndWhiteBalance()
            }
        } catch {
            logger.log(.error, category: "Camera", "Failed to unlock for re-meter: \(error.localizedDescription)")
        }
    }

    func applyManualCameraControls() {
        guard settings.useManualControls,
              let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        let format = device.activeFormat

        let clampedISO = min(max(settings.manualISO, format.minISO), format.maxISO)
        let minSec = CMTimeGetSeconds(format.minExposureDuration)
        let maxSec = min(1.0 / 10.0, CMTimeGetSeconds(format.maxExposureDuration))
        let clampedSec = min(max(settings.manualExposureDurationSeconds, minSec), maxSec)
        let duration = CMTimeMakeWithSeconds(clampedSec, preferredTimescale: 1_000_000_000)
        let clampedBias = min(max(settings.exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias)

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            device.setExposureTargetBias(clampedBias, completionHandler: nil)

            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: min(max(settings.whiteBalanceKelvin, 2000), 8000),
                tint: 0
            )
            var gains = device.deviceWhiteBalanceGains(for: tt)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1.0), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1.0), maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        } catch {
            logger.log(.error, category: "Camera", "Manual camera config failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Formats & Bounds

    private func detectSupportedVideoFormats() {
        let found = ResolutionPreset.allCases.filter { preset in
            ARWorldTrackingConfiguration.supportedVideoFormats.contains { Int($0.imageResolution.width) == preset.targetWidth }
        }
        availableResolutions = found.isEmpty ? [.fullHD1080p] : found
    }

    private func bestVideoFormat(for preset: ResolutionPreset) -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let exact = formats.filter { Int($0.imageResolution.width) == preset.targetWidth }
        return exact.max(by: { $0.framesPerSecond < $1.framesPerSecond }) ?? formats.first
    }

    private func refreshHardwareBounds() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        let f = device.activeFormat
        hardwareBounds = CameraHardwareBounds(
            minISO: f.minISO,
            maxISO: f.maxISO,
            minExposureSeconds: CMTimeGetSeconds(f.minExposureDuration),
            maxExposureSeconds: min(1.0 / 10.0, CMTimeGetSeconds(f.maxExposureDuration)),
            minExposureBias: device.minExposureTargetBias,
            maxExposureBias: device.maxExposureTargetBias
        )
    }

    // MARK: - Tracking

    private func updateTrackingStatus(_ state: ARCamera.TrackingState) {
        let newStatus: TrackingRecoveryStatus
        switch state {
        case .normal:
            newStatus = TrackingRecoveryStatus(stateTitle: "Tracking OK", guidanceMessage: nil, isHealthy: true)
        case .notAvailable:
            newStatus = TrackingRecoveryStatus(stateTitle: "Tracking Unavailable", guidanceMessage: "Hold steady while ARKit initializes.")
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                newStatus = TrackingRecoveryStatus(stateTitle: "Slow Down", guidanceMessage: "Moving too fast. Sweep the camera slowly.")
            case .insufficientFeatures:
                newStatus = TrackingRecoveryStatus(stateTitle: "Low Visual Features", guidanceMessage: "Aim at textured surfaces or improve lighting.")
            case .relocalizing:
                newStatus = TrackingRecoveryStatus(stateTitle: "Relocalizing", guidanceMessage: "Point back toward a previously scanned area.")
            case .initializing:
                newStatus = TrackingRecoveryStatus(stateTitle: "Initializing", guidanceMessage: "Pan gently over the scene to lock tracking.")
            @unknown default:
                newStatus = TrackingRecoveryStatus(stateTitle: "Limited Tracking", guidanceMessage: "Move slowly toward textured geometry.")
            }
        }

        if newStatus != trackingStatus {
            if !newStatus.isHealthy {
                logger.log(.warning, category: "Tracking", "\(newStatus.stateTitle): \(newStatus.guidanceMessage ?? "")")
            }
            trackingStatus = newStatus
        }
    }
}

extension ARCaptureSessionManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        currentCameraPose = frame.camera.transform
        updateTrackingStatus(frame.camera.trackingState)
        onFrameUpdate?(frame)

        guard isRecording,
              case .normal = frame.camera.trackingState,
              let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let projectID = activeProjectID,
              let scan = currentScan else { return }

        var shouldCapture = false
        if settings.captureMode == .manualSingleShot {
            shouldCapture = pendingManualShot
            pendingManualShot = false
        } else if let lastPose = lastKeyframePose {
            let delta = CameraCalibration.poseDelta(from: lastPose, to: frame.camera.transform)
            shouldCapture = CameraCalibration.shouldCaptureScanAndGoKeyframe(
                elapsedSeconds: frame.timestamp - lastKeyframeTime,
                translationMeters: delta.translationMeters,
                rotationDegrees: delta.rotationDegrees,
                minInterval: settings.scanAndGoIntervalSeconds,
                minTranslation: settings.scanAndGoMinTranslationMeters,
                minRotation: settings.scanAndGoMinRotationDegrees
            )
        } else {
            shouldCapture = true
        }

        guard shouldCapture else { return }

        lastKeyframeTime = frame.timestamp
        lastKeyframePose = frame.camera.transform

        let rgbWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let rgbHeight = CVPixelBufferGetHeight(frame.capturedImage)
        let scaledIntrinsics = CameraCalibration.scaledIntrinsics(
            frame.camera.intrinsics,
            from: frame.camera.imageResolution,
            to: rgbWidth,
            targetHeight: rgbHeight
        )

        let queued = ScanProjectStore.shared.enqueueKeyframeWrite(
            projectID: projectID,
            scanID: scan.id,
            frameIndex: capturedFrameCount,
            timestamp: frame.timestamp,
            rgbBuffer: frame.capturedImage,
            depthBuffer: depthData.depthMap,
            confidenceBuffer: depthData.confidenceMap,
            intrinsics: scaledIntrinsics,
            transform: frame.camera.transform
        )
        if queued {
            capturedFrameCount += 1
            trajectoryPoses.append(frame.camera.transform)
            onKeyframeCaptured?(frame)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        logger.log(.error, category: "ARKit", "ARSession failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        logger.log(.warning, category: "ARKit", "ARSession interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        logger.log(.info, category: "ARKit", "ARSession interruption ended")
    }
}
