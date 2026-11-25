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
    @State private var isProcessing = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button {
                        runAutoMergeAndRefine()
                    } label: {
                        HStack {
                            Label(
                                scans.count > 1 ? "Auto-Merge & Refine Passes" : "Auto-Refine Scan",
                                systemImage: "wand.and.stars"
                            )
                            .font(.headline)
                            Spacer()
                            if isProcessing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isProcessing || scans.isEmpty)

                    Text(scans.count > 1
                         ? "Automatically aligns your passes together and tightens any camera drift."
                         : "Automatically tightens camera alignment to make the scan sharper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Visible Passes") {
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
                                ScanProjectStore.shared.saveAlignmentState(alignmentState, for: project.id)
                                engine.applyAlignmentState(alignmentState) { poses in
                                    onStateChanged(poses)
                                }
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

                if !alignmentState.scanTransforms.isEmpty {
                    Section {
                        Button("Reset Alignment", role: .destructive) {
                            alignmentState.scanTransforms.removeAll()
                            ScanProjectStore.shared.saveAlignmentState(alignmentState, for: project.id)
                            engine.applyAlignmentState(alignmentState) { poses in
                                onStateChanged(poses)
                            }
                            statusMessage = "Reset alignment to original positions."
                        }
                    }
                }
            }
            .navigationTitle("Merge & Align")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func runAutoMergeAndRefine() {
        guard !scans.isEmpty else { return }
        isProcessing = true
        statusMessage = nil

        let ordered = scans.sorted { $0.createdAt < $1.createdAt }
        let group = DispatchGroup()

        for scan in ordered where scan.frameCount >= 2 {
            group.enter()
            PointCloudRegistration.refineScanPoses(projectID: project.id, scanID: scan.id, settings: captureSettings) { _ in
                group.leave()
            }
        }

        group.notify(queue: .main) {
            engine.loadProjectFromDisk(projectID: project.id, settings: captureSettings) { poses in
                guard ordered.count >= 2, let reference = ordered.first else {
                    onStateChanged(poses)
                    isProcessing = false
                    statusMessage = "Scan refined!"
                    return
                }

                alignSequential(passes: Array(ordered.dropFirst()), onto: reference.id, index: 0)
            }
        }
    }

    private func alignSequential(passes: [ScanSessionMetadata], onto referenceID: UUID, index: Int) {
        if index >= passes.count {
            ScanProjectStore.shared.saveAlignmentState(alignmentState, for: project.id)
            engine.applyAlignmentState(alignmentState) { poses in
                onStateChanged(poses)
                isProcessing = false
                statusMessage = "Aligned and refined \(scans.count) passes!"
            }
            return
        }

        let pass = passes[index]
        engine.runICPAlignment(sourceScanID: pass.id, targetScanID: referenceID, state: alignmentState) { updated, _ in
            alignmentState = updated
            alignSequential(passes: passes, onto: referenceID, index: index + 1)
        }
    }
}
