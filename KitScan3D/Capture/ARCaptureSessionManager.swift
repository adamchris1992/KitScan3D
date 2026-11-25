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
    var maxWhiteBalanceGain: Float = 4.0
}

struct TrackingRecoveryStatus: Equatable {
    var stateTitle: String = "Initializing"
    var guidanceMessage: String? = "Move your iPhone slowly to initialize tracking."
    var isHealthy: Bool = false
}

/// Manages ARSession, LiDAR depth, 1080p/4K format selection, AutoMagic/manual exposure & WB, and Scan & Go triggers.
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
    @Published private(set) var currentScan: ScanSessionMetadata?

    var onFrameUpdate: ((ARFrame) -> Void)?
    var onKeyframeCaptured: ((ARFrame, Int) -> Void)?

    private var activeProject: ScanProjectMetadata?
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

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }

        if let format = bestVideoFormat(for: settings.resolution) {
            config.videoFormat = format
            logger.log(.info, category: "ARKit", "Selected video format: \(Int(format.imageResolution.width))x\(Int(format.imageResolution.height)) @ \(format.framesPerSecond)fps")
        }

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
        refreshHardwareBounds()

        if settings.isAutoMagicLocked {
            // Allow 0.6s for initial auto-metering before locking
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.lockAutoMagicExposureAndWhiteBalance()
            }
        }
    }

    func pauseSession() {
        if isRecording {
            stopRecording()
        }
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

    func startRecording(in project: ScanProjectMetadata? = nil) {
        guard isSessionRunning, !isRecording else { return }
        let targetProject = project ?? ScanProjectStore.shared.ensureActiveProject()
        activeProject = targetProject

        let width = settings.resolution.targetWidth
        let height = settings.resolution == .uhd4K ? 2160 : 1080
        let scan = ScanProjectStore.shared.beginNewScanSession(in: targetProject, width: width, height: height)

        currentScan = scan
        capturedFrameCount = 0
        lastKeyframeTime = 0
        lastKeyframePose = nil
        trajectoryPoses.removeAll()
        isRecording = true

        if settings.isAutoMagicLocked && !settings.useManualControls {
            lockAutoMagicExposureAndWhiteBalance()
        }
        logger.log(.info, category: "Capture", "Recording started (\(settings.captureMode.rawValue), \(settings.resolution.rawValue))")
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let project = activeProject, var scan = currentScan {
            scan.frameCount = capturedFrameCount
            ScanProjectStore.shared.updateScanStats(projectID: project.id, scan: scan)
            currentScan = scan
        }
        logger.log(.info, category: "Capture", "Recording stopped. Total keyframes: \(capturedFrameCount)")
    }

    func triggerManualShot() {
        guard isRecording else { return }
        pendingManualShot = true
    }

    /// AutoMagic: briefly unlocks to meter ambient light, or locks current exposure & white balance so frames match.
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
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
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

            if settings.useManualControls {
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
            }
        } catch {
            logger.log(.error, category: "Camera", "Manual camera config failed: \(error.localizedDescription)")
        }
    }

    private func detectSupportedVideoFormats() {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        var found: [ResolutionPreset] = []
        if formats.contains(where: { Int($0.imageResolution.width) == 1920 }) {
            found.append(.fullHD1080p)
        }
        if formats.contains(where: { Int($0.imageResolution.width) == 3840 }) {
            found.append(.uhd4K)
        }
        if found.isEmpty {
            found = [.fullHD1080p]
        }
        availableResolutions = found
    }

    private func bestVideoFormat(for preset: ResolutionPreset) -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let exact = formats.filter { Int($0.imageResolution.width) == preset.targetWidth }
        if let preferred = exact.max(by: { $0.framesPerSecond < $1.framesPerSecond }) {
            return preferred
        }
        return formats.first
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
            maxExposureBias: device.maxExposureTargetBias,
            maxWhiteBalanceGain: device.maxWhiteBalanceGain
        )
    }

    private func updateTrackingStatus(_ state: ARCamera.TrackingState) {
        let newStatus: TrackingRecoveryStatus
        switch state {
        case .normal:
            newStatus = TrackingRecoveryStatus(stateTitle: "Tracking OK", guidanceMessage: nil, isHealthy: true)
        case .notAvailable:
            newStatus = TrackingRecoveryStatus(
                stateTitle: "Tracking Unavailable",
                guidanceMessage: "Hold steady while ARKit initializes.",
                isHealthy: false
            )
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                newStatus = TrackingRecoveryStatus(
                    stateTitle: "Slow Down",
                    guidanceMessage: "Moving too fast. Sweep the camera slowly.",
                    isHealthy: false
                )
            case .insufficientFeatures:
                newStatus = TrackingRecoveryStatus(
                    stateTitle: "Low Visual Features",
                    guidanceMessage: "Aim at textured surfaces or improve lighting.",
                    isHealthy: false
                )
            case .relocalizing:
                newStatus = TrackingRecoveryStatus(
                    stateTitle: "Relocalizing",
                    guidanceMessage: "Point back toward a previously scanned area.",
                    isHealthy: false
                )
            case .initializing:
                newStatus = TrackingRecoveryStatus(
                    stateTitle: "Initializing",
                    guidanceMessage: "Pan gently over the scene to lock tracking.",
                    isHealthy: false
                )
            @unknown default:
                newStatus = TrackingRecoveryStatus(
                    stateTitle: "Limited Tracking",
                    guidanceMessage: "Move slowly toward textured geometry.",
                    isHealthy: false
                )
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

        guard isRecording else { return }
        guard case .normal = frame.camera.trackingState else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        var shouldCapture = false
        if settings.captureMode == .manualSingleShot {
            if pendingManualShot {
                pendingManualShot = false
                shouldCapture = true
            }
        } else {
            if let lastPose = lastKeyframePose {
                let elapsed = frame.timestamp - lastKeyframeTime
                let delta = CameraCalibration.poseDelta(from: lastPose, to: frame.camera.transform)
                shouldCapture = CameraCalibration.shouldCaptureScanAndGoKeyframe(
                    elapsedSeconds: elapsed,
                    translationMeters: delta.translationMeters,
                    rotationDegrees: delta.rotationDegrees,
                    minInterval: settings.scanAndGoIntervalSeconds,
                    minTranslation: settings.scanAndGoMinTranslationMeters,
                    minRotation: settings.scanAndGoMinRotationDegrees
                )
            } else {
                shouldCapture = true
            }
        }

        guard shouldCapture else { return }

        let index = capturedFrameCount
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

        if let project = activeProject, let scan = currentScan {
            let queued = ScanProjectStore.shared.enqueueKeyframeWrite(
                projectID: project.id,
                scanID: scan.id,
                frameIndex: index,
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
                onKeyframeCaptured?(frame, index)
            }
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
