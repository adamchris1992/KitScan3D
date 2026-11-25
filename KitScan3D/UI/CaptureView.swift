import SwiftUI
import ARKit
import simd

enum MapOverlayMode: String, CaseIterable {
    case hidden = "Cam"
    case map2D = "2D"
    case view3D = "3D"
}

enum LiveCameraAdjustment: String, CaseIterable {
    case whiteBalance = "White Balance"
    case shutter = "Shutter"
    case iso = "ISO"
    case exposureBias = "Exposure"
}

struct CaptureView: View {
    let project: ScanProjectMetadata
    @ObservedObject var captureManager: ARCaptureSessionManager
    @ObservedObject var engine: MetalPointCloudEngine
    @ObservedObject private var store = ScanProjectStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showSettingsSheet = false
    @State private var mapMode: MapOverlayMode = .map2D
    @State private var showScanComplete = false
    @State private var toastMessage: String?
    @State private var activeAdjustment: LiveCameraAdjustment? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LiveCameraMetalView(engine: engine)
                    .ignoresSafeArea()

                VStack(spacing: 8) {
                    topHUD
                    statusSubRow
                    trackingBanner
                    if let toastMessage {
                        Text(toastMessage)
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.75), in: Capsule())
                            .transition(.opacity)
                    }
                    Spacer()

                    if mapMode != .hidden {
                        HStack {
                            Spacer()
                            miniMapCard
                        }
                        .padding(.horizontal, 14)
                    }

                    bottomControls
                }
                .padding(.vertical, 6)
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                captureManager.onFrameUpdate = { frame in
                    engine.updateLiveFrame(frame, viewportSize: geo.size)
                }
                captureManager.onKeyframeCaptured = { frame in
                    engine.processCapturedKeyframe(frame, settings: captureManager.settings)
                }
                captureManager.startSession(for: project.id)
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
                captureManager.pauseSession()
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            CameraControlsSheet(captureManager: captureManager)
        }
        .fullScreenCover(isPresented: $showScanComplete) {
            ScanCompleteResultView(
                projectName: project.name,
                keyframeCount: captureManager.capturedFrameCount,
                engine: engine,
                trajectoryPoses: captureManager.trajectoryPoses,
                onBackToProjects: {
                    showScanComplete = false
                    dismiss()
                },
                onScanAnotherPass: {
                    showScanComplete = false
                    captureManager.startSession(for: project.id)
                }
            )
        }
    }

    private var topHUD: some View {
        HStack {
            Button {
                captureManager.pauseSession()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(captureManager.trackingStatus.isHealthy ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(captureManager.trackingStatus.stateTitle)
                    .font(.caption.bold())
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)

            Spacer()

            Color.clear
                .frame(width: 40, height: 40)
        }
        .padding(.horizontal, 14)
    }

    private var statusSubRow: some View {
        HStack {
            Label("4K • \(captureManager.settings.profile.rawValue)", systemImage: captureManager.settings.profile == .objectOrbit ? "cube.transparent" : "camera.aperture")
                .font(.caption2.bold())
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .fixedSize(horizontal: true, vertical: false)

            Spacer()

            HStack(spacing: 10) {
                Label("\(captureManager.capturedFrameCount)", systemImage: "photo.stack")
                    .lineLimit(1)
                Label(formatPointCount(engine.totalPointCount), systemImage: "circle.grid.3x3")
                    .lineLimit(1)
                if store.pendingWriteCount > 0 {
                    Label("\(store.pendingWriteCount)", systemImage: "internaldrive")
                        .foregroundStyle(.yellow)
                        .lineLimit(1)
                }
            }
            .font(.caption2.monospacedDigit().bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private var trackingBanner: some View {
        if let guidance = captureManager.trackingStatus.guidanceMessage,
           !captureManager.trackingStatus.isHealthy {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(guidance)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }

    private var miniMapCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("LIVE MAP")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                Spacer()

                Button {
                    mapMode = .map2D
                } label: {
                    Text("2D")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(mapMode == .map2D ? Color.white.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                Button {
                    mapMode = .view3D
                } label: {
                    Text("3D")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(mapMode == .view3D ? Color.white.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            .padding(6)
            .zIndex(10)

            Group {
                if mapMode == .map2D {
                    TopDown2DMapView(
                        points2D: engine.preview2DPoints,
                        trajectoryPoses: captureManager.trajectoryPoses,
                        currentPose: captureManager.currentCameraPose
                    )
                } else {
                    PointCloud3DMetalView(
                        engine: engine,
                        trajectoryPoses: captureManager.trajectoryPoses,
                        currentPose: captureManager.currentCameraPose
                    )
                }
            }
            .clipped()
        }
        .frame(width: 174, height: 196)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if let activeAdjustment {
                liveAdjustmentSlider(for: activeAdjustment)
            }

            // Compact Camera Quick-Bar with live inline adjustments
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    Button {
                        activeAdjustment = nil
                        captureManager.unlockAndRemeterAutoMagic()
                        showToast("Re-metering exposure & WB...")
                    } label: {
                        QuickBarChip(
                            icon: "sparkles",
                            title: captureManager.settings.isAutoMagicLocked ? "Locked" : "Auto",
                            isActive: captureManager.settings.isAutoMagicLocked && !captureManager.settings.useManualControls
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        toggleAdjustment(.whiteBalance)
                    } label: {
                        QuickBarChip(
                            icon: "thermometer.medium",
                            title: "\(Int(captureManager.settings.whiteBalanceKelvin))K",
                            isActive: activeAdjustment == .whiteBalance
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        toggleAdjustment(.shutter)
                    } label: {
                        let inv = Int(round(1.0 / max(0.0001, captureManager.settings.manualExposureDurationSeconds)))
                        QuickBarChip(
                            icon: "timer",
                            title: "1/\(inv)",
                            isActive: activeAdjustment == .shutter
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        toggleAdjustment(.iso)
                    } label: {
                        QuickBarChip(
                            icon: "dial.low",
                            title: "ISO \(Int(captureManager.settings.manualISO))",
                            isActive: activeAdjustment == .iso
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        toggleAdjustment(.exposureBias)
                    } label: {
                        QuickBarChip(
                            icon: "plusminus",
                            title: String(format: "%+.1f", captureManager.settings.exposureBias),
                            isActive: activeAdjustment == .exposureBias
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        mapMode = mapMode == .hidden ? .map2D : .hidden
                    } label: {
                        QuickBarChip(
                            icon: "map",
                            title: "Map",
                            isActive: mapMode != .hidden
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 12)

            Text(captureManager.settings.captureMode == .scanAndGo
                 ? (captureManager.isRecording ? "RECORDING" : (captureManager.currentScan != nil ? "PAUSED" : "AUTO SCAN"))
                 : (captureManager.isRecording ? "MANUAL SHOT" : (captureManager.currentScan != nil ? "PAUSED" : "MANUAL")))
                .font(.caption2.bold())
                .tracking(1.4)
                .foregroundStyle(captureManager.isRecording ? Color.red : .white.opacity(0.85))

            HStack(spacing: 24) {
                Button {
                    showSettingsSheet = true
                } label: {
                    Label("Controls", systemImage: "slider.horizontal.3")
                        .font(.caption.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                // Main Record / Pause button
                Button {
                    if captureManager.isRecording {
                        captureManager.pauseRecording()
                    } else {
                        if captureManager.currentScan == nil {
                            engine.resetPointCloud()
                        }
                        captureManager.startRecording(in: project.id)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                            .frame(width: 72, height: 72)
                        if captureManager.isRecording {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red)
                                .frame(width: 28, height: 28)
                        } else {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 58, height: 58)
                        }
                    }
                }

                if captureManager.settings.captureMode == .manualSingleShot && captureManager.isRecording {
                    Button {
                        captureManager.triggerManualShot()
                    } label: {
                        Label("Snap", systemImage: "camera.shutter.button.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.green.opacity(0.35), in: Capsule())
                    }
                } else if captureManager.capturedFrameCount > 0 {
                    Button {
                        captureManager.finishRecording()
                        captureManager.pauseSession()
                        engine.flushRenderBuffer {
                            showScanComplete = true
                        }
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.caption.bold())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.green.opacity(0.45), in: Capsule())
                    }
                } else {
                    Color.clear
                        .frame(width: 84, height: 36)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func toggleAdjustment(_ adj: LiveCameraAdjustment) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if activeAdjustment == adj {
                activeAdjustment = nil
            } else {
                activeAdjustment = adj
                captureManager.settings.useManualControls = true
                captureManager.settings.isAutoMagicLocked = false
                captureManager.applyManualCameraControls()
            }
        }
    }

    @ViewBuilder
    private func liveAdjustmentSlider(for adj: LiveCameraAdjustment) -> some View {
        let bounds = captureManager.hardwareBounds
        VStack(spacing: 6) {
            HStack {
                Text(adj.rawValue)
                    .font(.caption.bold())
                Spacer()
                Text(adjustmentValueLabel(for: adj))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.green)
                Button {
                    withAnimation { activeAdjustment = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            switch adj {
            case .iso:
                Slider(value: $captureManager.settings.manualISO, in: bounds.minISO...bounds.maxISO)
                    .onChange(of: captureManager.settings.manualISO) { _, _ in
                        captureManager.applyManualCameraControls()
                    }
            case .shutter:
                Slider(value: $captureManager.settings.manualExposureDurationSeconds, in: bounds.minExposureSeconds...bounds.maxExposureSeconds)
                    .onChange(of: captureManager.settings.manualExposureDurationSeconds) { _, _ in
                        captureManager.applyManualCameraControls()
                    }
            case .exposureBias:
                Slider(value: $captureManager.settings.exposureBias, in: bounds.minExposureBias...bounds.maxExposureBias)
                    .onChange(of: captureManager.settings.exposureBias) { _, _ in
                        captureManager.applyManualCameraControls()
                    }
            case .whiteBalance:
                Slider(value: $captureManager.settings.whiteBalanceKelvin, in: 2500...7500, step: 100)
                    .onChange(of: captureManager.settings.whiteBalanceKelvin) { _, _ in
                        captureManager.applyManualCameraControls()
                    }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 14)
    }

    private func adjustmentValueLabel(for adj: LiveCameraAdjustment) -> String {
        switch adj {
        case .iso:
            return "\(Int(captureManager.settings.manualISO))"
        case .shutter:
            let inv = Int(round(1.0 / max(0.0001, captureManager.settings.manualExposureDurationSeconds)))
            return "1/\(inv) s"
        case .exposureBias:
            return String(format: "%+.1f EV", captureManager.settings.exposureBias)
        case .whiteBalance:
            return "\(Int(captureManager.settings.whiteBalanceKelvin)) K"
        }
    }

    private func showToast(_ text: String) {
        withAnimation {
            toastMessage = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation {
                if toastMessage == text {
                    toastMessage = nil
                }
            }
        }
    }

    private func formatPointCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }
}

struct QuickBarChip: View {
    let icon: String
    let title: String
    let isActive: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(isActive ? Color.green : .white)
            Text(title)
                .font(.caption2)
                .foregroundStyle(isActive ? Color.green : .white.opacity(0.8))
        }
        .frame(minWidth: 46)
    }
}

struct ScanCompleteResultView: View {
    let projectName: String
    let keyframeCount: Int
    @ObservedObject var engine: MetalPointCloudEngine
    let trajectoryPoses: [simd_float4x4]
    let onBackToProjects: () -> Void
    let onScanAnotherPass: () -> Void

    @State private var showTrajectory = true
    @State private var pointSize: Float = 3.4

    var body: some View {
        ZStack {
            PointCloud3DMetalView(
                engine: engine,
                trajectoryPoses: trajectoryPoses,
                currentPose: trajectoryPoses.last ?? matrix_identity_float4x4,
                showLiveFrustum: false,
                showTrajectory: showTrajectory,
                pointSize: pointSize
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        onBackToProjects()
                    } label: {
                        Label("Projects", systemImage: "chevron.left")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Label("Scan Complete", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.green)
                        Text("\(projectName) • \(keyframeCount) frames • \(engine.totalPointCount.formatted()) pts")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .padding()

                HStack {
                    Button {
                        showTrajectory.toggle()
                    } label: {
                        Image(systemName: showTrajectory ? "point.topleft.down.curvedto.point.bottomright.up.fill" : "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.subheadline)
                            .frame(width: 42, height: 42)
                            .background(showTrajectory ? Color.accentColor.opacity(0.4) : Color.black.opacity(0.45), in: Circle())
                    }
                    .padding(.leading, 14)

                    Spacer()
                }

                Spacer()

                HStack(spacing: 16) {
                    Button {
                        onScanAnotherPass()
                    } label: {
                        Label("Scan Another Pass", systemImage: "camera.viewfinder")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onBackToProjects()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 20)
            }
        }
    }
}
