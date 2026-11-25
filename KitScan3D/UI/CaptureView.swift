import SwiftUI
import ARKit
import simd

enum MapOverlayMode: String, CaseIterable {
    case hidden = "Cam"
    case map2D = "2D"
    case view3D = "3D"
}

struct CaptureView: View {
    let project: ScanProjectMetadata
    @ObservedObject var captureManager: ARCaptureSessionManager
    @ObservedObject var engine: MetalPointCloudEngine
    @ObservedObject private var store = ScanProjectStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showSettingsSheet = false
    @State private var mapMode: MapOverlayMode = .map2D
    @State private var isFullScreen3D = false
    @State private var showScanComplete = false
    @State private var toastMessage: String?
    @State private var frameTick = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isFullScreen3D {
                    PointCloud3DMetalView(
                        engine: engine,
                        trajectoryPoses: captureManager.trajectoryPoses,
                        currentPose: captureManager.currentCameraPose,
                        showLiveFrustum: false
                    )
                    .ignoresSafeArea()
                    if engine.totalPointCount == 0 {
                        VStack(spacing: 8) {
                            Image(systemName: "cube.transparent")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No 3D points captured yet.\nTap Record to scan.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    LiveCameraMetalView(engine: engine, settings: captureManager.settings)
                        .ignoresSafeArea()
                }

                VStack(spacing: 12) {
                    topHUD
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

                    if !isFullScreen3D && mapMode != .hidden {
                        HStack {
                            Spacer()
                            miniMapCard
                        }
                        .padding(.horizontal)
                    }

                    bottomControls
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                captureManager.onFrameUpdate = { frame in
                    engine.updateLiveFrame(frame, viewportSize: geo.size)
                    frameTick &+= 1
                    if captureManager.settings.showCoverageOverlay && frameTick % 6 == 0 {
                        engine.updateCoverageMask(for: frame, settings: captureManager.settings)
                    }
                }
                captureManager.onKeyframeCaptured = { frame, _ in
                    engine.processCapturedKeyframe(frame, settings: captureManager.settings)
                }
                captureManager.startSession()
            }
            .onDisappear {
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
                    captureManager.startSession()
                }
            )
        }
    }

    private var topHUD: some View {
        HStack(spacing: 8) {
            Button {
                captureManager.pauseSession()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.bold())
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(captureManager.trackingStatus.isHealthy ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(captureManager.trackingStatus.stateTitle)
                    .font(.caption.bold())
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            HStack(spacing: 8) {
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
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)

            Button {
                isFullScreen3D.toggle()
            } label: {
                Image(systemName: isFullScreen3D ? "camera.fill" : "cube.fill")
                    .font(.subheadline)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 12)
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
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }

    private var miniMapCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    mapMode = .map2D
                } label: {
                    Text("2D Map")
                        .font(.caption2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(mapMode == .map2D ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                Button {
                    mapMode = .view3D
                } label: {
                    Text("3D Cloud")
                        .font(.caption2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(mapMode == .view3D ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
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
        .frame(width: 174, height: 198)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Toggle("Depth", isOn: $captureManager.settings.showLiveDepthPreview)
                    .toggleStyle(.button)
                    .font(.caption.bold())
                Toggle("Coverage", isOn: $captureManager.settings.showCoverageOverlay)
                    .toggleStyle(.button)
                    .font(.caption.bold())

                Button {
                    mapMode = mapMode == .hidden ? .map2D : .hidden
                } label: {
                    Label(mapMode == .hidden ? "Show Map" : "Hide Map", systemImage: "map")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            HStack(spacing: 28) {
                Button {
                    showSettingsSheet = true
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title3)
                        Text("Controls")
                            .font(.caption2)
                    }
                    .frame(width: 60)
                }

                // Main Record / Stop button
                Button {
                    if captureManager.isRecording {
                        captureManager.stopRecording()
                        captureManager.pauseSession()
                        showScanComplete = true
                    } else {
                        isFullScreen3D = false
                        engine.resetPointCloud()
                        captureManager.startRecording(in: project)
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
                                .fill(Color.red)
                                .frame(width: 58, height: 58)
                        }
                    }
                }

                if captureManager.settings.captureMode == .manualSingleShot && captureManager.isRecording {
                    Button {
                        captureManager.triggerManualShot()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "camera.shutter.button.fill")
                                .font(.title2)
                            Text("Snap")
                                .font(.caption2)
                        }
                        .frame(width: 60)
                    }
                } else {
                    Button {
                        captureManager.unlockAndRemeterAutoMagic()
                        showToast("Re-metering exposure & WB...")
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                                .font(.title3)
                            Text("Re-Meter")
                                .font(.caption2)
                        }
                        .frame(width: 60)
                    }
                }
            }
            .padding(.bottom, 10)
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

struct ScanCompleteResultView: View {
    let projectName: String
    let keyframeCount: Int
    @ObservedObject var engine: MetalPointCloudEngine
    let trajectoryPoses: [simd_float4x4]
    let onBackToProjects: () -> Void
    let onScanAnotherPass: () -> Void

    var body: some View {
        ZStack {
            PointCloud3DMetalView(
                engine: engine,
                trajectoryPoses: trajectoryPoses,
                currentPose: trajectoryPoses.last ?? matrix_identity_float4x4,
                showLiveFrustum: false
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        onBackToProjects()
                    } label: {
                        Label("Back to Projects", systemImage: "chevron.left")
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
