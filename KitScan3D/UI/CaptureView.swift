import SwiftUI
import ARKit

enum MapOverlayMode: String, CaseIterable {
    case hidden = "Cam"
    case map2D = "2D Map"
    case view3D = "3D Cloud"
}

struct CaptureView: View {
    @ObservedObject var captureManager: ARCaptureSessionManager
    @ObservedObject var engine: MetalPointCloudEngine
    @ObservedObject private var store = ScanProjectStore.shared

    @State private var showSettingsSheet = false
    @State private var mapMode: MapOverlayMode = .map2D
    @State private var isFullScreen3D = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isFullScreen3D {
                    PointCloud3DMetalView(
                        engine: engine,
                        trajectoryPoses: captureManager.trajectoryPoses,
                        currentPose: captureManager.currentCameraPose
                    )
                    .ignoresSafeArea()
                } else {
                    LiveCameraMetalView(engine: engine, settings: captureManager.settings)
                        .ignoresSafeArea()
                }

                VStack(spacing: 12) {
                    topHUD
                    trackingBanner
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
    }

    private var topHUD: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(captureManager.trackingStatus.isHealthy ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(captureManager.trackingStatus.stateTitle)
                    .font(.caption.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            HStack(spacing: 12) {
                Label("\(captureManager.capturedFrameCount)", systemImage: "photo.stack")
                Label(formatPointCount(engine.totalPointCount), systemImage: "circle.grid.3x3")
                if store.pendingWriteCount > 0 {
                    Label("\(store.pendingWriteCount)", systemImage: "internaldrive")
                        .foregroundStyle(.yellow)
                }
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())

            Button {
                isFullScreen3D.toggle()
            } label: {
                Image(systemName: isFullScreen3D ? "camera.fill" : "cube.fill")
                    .font(.subheadline)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal)
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
            HStack {
                Picker("Overlay", selection: $mapMode) {
                    ForEach(MapOverlayMode.allCases.filter { $0 != .hidden }, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(6)

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
        .frame(width: 170, height: 195)
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
                    } else {
                        engine.resetPointCloud()
                        captureManager.startRecording()
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

    private func formatPointCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }
}
