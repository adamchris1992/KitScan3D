import SwiftUI

struct CameraControlsSheet: View {
    @ObservedObject var captureManager: ARCaptureSessionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Resolution") {
                    Picker("Resolution", selection: Binding(
                        get: { captureManager.settings.resolution },
                        set: { captureManager.applyResolution($0) }
                    )) {
                        ForEach(captureManager.availableResolutions) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Lens")
                        Spacer()
                        Text("24 mm (Wide)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Exposure & White Balance") {
                    Toggle("AutoMagic Lock", isOn: Binding(
                        get: { captureManager.settings.isAutoMagicLocked },
                        set: { locked in
                            if locked {
                                captureManager.lockAutoMagicExposureAndWhiteBalance()
                            } else {
                                captureManager.unlockAndRemeterAutoMagic()
                            }
                        }
                    ))

                    Toggle("Manual Controls", isOn: $captureManager.settings.useManualControls)
                        .onChange(of: captureManager.settings.useManualControls) { _, enabled in
                            if enabled {
                                captureManager.settings.isAutoMagicLocked = false
                                captureManager.applyManualCameraControls()
                            }
                        }

                    if captureManager.settings.useManualControls {
                        let bounds = captureManager.hardwareBounds

                        VStack(alignment: .leading) {
                            Text("ISO: \(Int(captureManager.settings.manualISO))")
                            Slider(
                                value: $captureManager.settings.manualISO,
                                in: bounds.minISO...bounds.maxISO
                            )
                            .onChange(of: captureManager.settings.manualISO) { _, _ in
                                captureManager.applyManualCameraControls()
                            }
                        }

                        VStack(alignment: .leading) {
                            let inv = Int(round(1.0 / max(0.0001, captureManager.settings.manualExposureDurationSeconds)))
                            Text("Shutter: 1/\(inv) s")
                            Slider(
                                value: $captureManager.settings.manualExposureDurationSeconds,
                                in: bounds.minExposureSeconds...bounds.maxExposureSeconds
                            )
                            .onChange(of: captureManager.settings.manualExposureDurationSeconds) { _, _ in
                                captureManager.applyManualCameraControls()
                            }
                        }

                        VStack(alignment: .leading) {
                            Text(String(format: "Exposure Bias: %+.1f EV", captureManager.settings.exposureBias))
                            Slider(
                                value: $captureManager.settings.exposureBias,
                                in: bounds.minExposureBias...bounds.maxExposureBias
                            )
                            .onChange(of: captureManager.settings.exposureBias) { _, _ in
                                captureManager.applyManualCameraControls()
                            }
                        }

                        VStack(alignment: .leading) {
                            Text("White Balance: \(Int(captureManager.settings.whiteBalanceKelvin)) K")
                            Slider(
                                value: $captureManager.settings.whiteBalanceKelvin,
                                in: 2500...7500,
                                step: 100
                            )
                            .onChange(of: captureManager.settings.whiteBalanceKelvin) { _, _ in
                                captureManager.applyManualCameraControls()
                            }
                        }
                    }
                }

                Section("Capture Mode & Rate") {
                    Picker("Mode", selection: $captureManager.settings.captureMode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if captureManager.settings.captureMode == .scanAndGo {
                        VStack(alignment: .leading) {
                            Text(String(format: "Min Interval: %.2f s", captureManager.settings.scanAndGoIntervalSeconds))
                            Slider(value: $captureManager.settings.scanAndGoIntervalSeconds, in: 0.1...2.0, step: 0.05)
                        }
                        VStack(alignment: .leading) {
                            Text(String(format: "Min Translation: %.2f m", captureManager.settings.scanAndGoMinTranslationMeters))
                            Slider(value: $captureManager.settings.scanAndGoMinTranslationMeters, in: 0.03...0.50, step: 0.01)
                        }
                        VStack(alignment: .leading) {
                            Text(String(format: "Min Rotation: %.0f°", captureManager.settings.scanAndGoMinRotationDegrees))
                            Slider(value: $captureManager.settings.scanAndGoMinRotationDegrees, in: 2...30, step: 1)
                        }
                    }
                }

                Section("Depth Clipping & Point Spacing") {
                    VStack(alignment: .leading) {
                        Text(String(format: "Near Clip: %.2f m", captureManager.settings.nearClipMeters))
                        Slider(value: $captureManager.settings.nearClipMeters, in: 0.1...5.0, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Far Clip: %.2f m", captureManager.settings.farClipMeters))
                        Slider(value: $captureManager.settings.farClipMeters, in: 0.5...20.0, step: 0.25)
                        Text("LiDAR hardware accuracy is highest within 0.3 m – 5.0 m.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Point Spacing", selection: $captureManager.settings.spacingMode) {
                        ForEach(PointSpacingMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    if captureManager.settings.spacingMode == .manual {
                        VStack(alignment: .leading) {
                            let mm = Int(round(captureManager.settings.manualSpacingMeters * 1000))
                            Text("Voxel Spacing: \(mm) mm")
                            Slider(value: $captureManager.settings.manualSpacingMeters, in: 0.001...0.05, step: 0.001)
                        }
                    }

                    Stepper(
                        "Max Points: \(captureManager.settings.maxPointBudget / 1000)K",
                        value: $captureManager.settings.maxPointBudget,
                        in: 250_000...4_000_000,
                        step: 250_000
                    )
                }

                Section {
                    Button("Reset Scan Defaults", role: .destructive) {
                        captureManager.settings.resetScanDefaults()
                    }
                }
            }
            .navigationTitle("Camera & Scan")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
