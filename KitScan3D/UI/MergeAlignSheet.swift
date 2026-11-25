import SwiftUI
import simd

struct MergeAlignSheet: View {
    let project: ScanProjectMetadata
    let scans: [ScanSessionMetadata]
    @ObservedObject var engine: MetalPointCloudEngine
    let captureSettings: CaptureSettings
    @Binding var alignmentState: ProjectAlignmentState
    let onStateChanged: ([simd_float4x4]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sourceScanID: UUID?
    @State private var targetScanID: UUID?
    @State private var manualX: Float = 0
    @State private var manualY: Float = 0
    @State private var manualZ: Float = 0
    @State private var manualYaw: Float = 0
    @State private var isProcessing = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Section("Scan Layers") {
                    ForEach(scans) { scan in
                        let isVisible = !alignmentState.hiddenScanIDs.contains(scan.id.uuidString)
                        Toggle(isOn: Binding(
                            get: { isVisible },
                            set: { visible in
                                if visible {
                                    alignmentState.hiddenScanIDs.removeAll { $0 == scan.id.uuidString }
                                } else if !alignmentState.hiddenScanIDs.contains(scan.id.uuidString) {
                                    alignmentState.hiddenScanIDs.append(scan.id.uuidString)
                                }
                                persistAndApply()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(scan.name)
                                    .font(.headline)
                                Text("\(scan.frameCount) frames • \(scan.resolutionWidth)×\(scan.resolutionHeight)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if scans.count >= 2 {
                    Section("Multi-Pass Alignment (ICP)") {
                        Picker("Align Pass", selection: $sourceScanID) {
                            ForEach(scans) { scan in
                                Text(scan.name).tag(Optional(scan.id))
                            }
                        }
                        .onChange(of: sourceScanID) { _, newID in
                            loadManualSliders(for: newID)
                        }

                        Picker("Onto Reference", selection: $targetScanID) {
                            ForEach(scans) { scan in
                                Text(scan.name).tag(Optional(scan.id))
                            }
                        }

                        Button {
                            runICP()
                        } label: {
                            HStack {
                                Label("Auto-Align (ICP)", systemImage: "wand.and.stars")
                                Spacer()
                                if isProcessing { ProgressView() }
                            }
                        }
                        .disabled(isProcessing || sourceScanID == nil || targetScanID == nil || sourceScanID == targetScanID)
                    }

                    if let srcID = sourceScanID {
                        Section("Manual Coarse Offset") {
                            VStack(alignment: .leading) {
                                Text(String(format: "Offset X: %+.2f m", manualX))
                                Slider(value: $manualX, in: -2.0...2.0, step: 0.01)
                            }
                            VStack(alignment: .leading) {
                                Text(String(format: "Offset Y: %+.2f m", manualY))
                                Slider(value: $manualY, in: -2.0...2.0, step: 0.01)
                            }
                            VStack(alignment: .leading) {
                                Text(String(format: "Offset Z: %+.2f m", manualZ))
                                Slider(value: $manualZ, in: -2.0...2.0, step: 0.01)
                            }
                            VStack(alignment: .leading) {
                                Text(String(format: "Yaw: %+.0f°", manualYaw))
                                Slider(value: $manualYaw, in: -180...180, step: 1)
                            }

                            Button("Apply Manual Offset") {
                                let t = PointCloudRegistration.makeTransform(
                                    translation: SIMD3<Float>(manualX, manualY, manualZ),
                                    yawDegrees: manualYaw
                                )
                                alignmentState.setTransform(t, for: srcID)
                                persistAndApply()
                                statusMessage = "Applied manual offset."
                            }

                            Button("Reset Pass Alignment", role: .destructive) {
                                alignmentState.scanTransforms.removeValue(forKey: srcID.uuidString)
                                loadManualSliders(for: srcID)
                                persistAndApply()
                                statusMessage = "Reset pass alignment to identity."
                            }
                        }
                    }
                }

                Section("On-Device RGB-D Refinement") {
                    ForEach(scans) { scan in
                        Button {
                            runRefinement(for: scan)
                        } label: {
                            HStack {
                                Label("Refine \(scan.name) Poses", systemImage: "scope")
                                Spacer()
                                if isProcessing { ProgressView() }
                            }
                        }
                        .disabled(isProcessing || scan.frameCount < 2)
                    }
                    Text("Refines keyframe poses using sliding-window ICP while keeping raw captures intact.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Merge & Align")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if sourceScanID == nil {
                    sourceScanID = scans.first?.id
                }
                if targetScanID == nil {
                    targetScanID = scans.dropFirst().first?.id ?? scans.first?.id
                }
                loadManualSliders(for: sourceScanID)
            }
        }
    }

    private func loadManualSliders(for scanID: UUID?) {
        guard let scanID else { return }
        let dec = PointCloudRegistration.decompose(alignmentState.transform(for: scanID))
        manualX = dec.translation.x
        manualY = dec.translation.y
        manualZ = dec.translation.z
        manualYaw = dec.yawDegrees
    }

    private func persistAndApply() {
        ScanProjectStore.shared.saveAlignmentState(alignmentState, for: project.id)
        engine.applyAlignmentState(alignmentState) { poses in
            onStateChanged(poses)
        }
    }

    private func runICP() {
        guard let src = sourceScanID, let tgt = targetScanID, src != tgt else { return }
        isProcessing = true
        engine.runICPAlignment(sourceScanID: src, targetScanID: tgt, state: alignmentState) { updated, result in
            alignmentState = updated
            ScanProjectStore.shared.saveAlignmentState(updated, for: project.id)
            loadManualSliders(for: src)
            engine.applyAlignmentState(updated) { poses in
                onStateChanged(poses)
            }
            isProcessing = false
            if result.inlierCount >= 12 {
                statusMessage = String(format: "ICP aligned (%d correspondences, RMSE %.1f cm)", result.inlierCount, result.rmse * 100)
            } else {
                statusMessage = "ICP found too few overlapping points. Try a manual coarse offset first."
            }
        }
    }

    private func runRefinement(for scan: ScanSessionMetadata) {
        isProcessing = true
        PointCloudRegistration.refineScanPoses(projectID: project.id, scanID: scan.id, settings: captureSettings) { count in
            engine.loadProjectFromDisk(projectID: project.id, settings: captureSettings) { poses in
                onStateChanged(poses)
                isProcessing = false
                statusMessage = "Refined \(count) keyframe poses in \(scan.name)."
            }
        }
    }
}
