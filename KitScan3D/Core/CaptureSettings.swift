import Foundation

enum ResolutionPreset: String, CaseIterable, Codable, Identifiable {
    case fullHD1080p = "FHD"
    case uhd4K = "4K"

    var id: String { rawValue }
    var targetWidth: Int {
        switch self {
        case .fullHD1080p: return 1920
        case .uhd4K: return 3840
        }
    }
}

enum CaptureMode: String, CaseIterable, Codable, Identifiable {
    case scanAndGo = "Scan & Go"
    case manualSingleShot = "Manual Shot"

    var id: String { rawValue }
}

enum PointSpacingMode: String, CaseIterable, Codable, Identifiable {
    case adaptive = "Adaptive"
    case manual = "Manual"

    var id: String { rawValue }
}

struct CaptureSettings: Codable, Equatable {
    // Resolution
    var resolution: ResolutionPreset = .fullHD1080p

    // Exposure & White Balance
    var isAutoMagicLocked: Bool = true
    var useManualControls: Bool = false
    var manualISO: Float = 100
    var manualExposureDurationSeconds: Double = 1.0 / 60.0
    var exposureBias: Float = 0.0
    var whiteBalanceKelvin: Float = 5200

    // Capture Mode & Rate
    var captureMode: CaptureMode = .scanAndGo
    var scanAndGoIntervalSeconds: Double = 0.16
    var scanAndGoMinTranslationMeters: Float = 0.05
    var scanAndGoMinRotationDegrees: Float = 4.0

    // Depth Clipping (0 - 20 m)
    var nearClipMeters: Float = 0.20
    var farClipMeters: Float = 5.00
    var minDepthConfidence: Int = 2 // 0 = low, 1 = medium, 2 = high

    // Point Cloud Density & Budget
    var spacingMode: PointSpacingMode = .adaptive
    var manualSpacingMeters: Float = 0.005 // 1 mm (0.001) to 5 cm (0.05)
    var maxPointBudget: Int = 3_000_000

    /// Restores scan-quality defaults while keeping the chosen resolution and current exposure lock state.
    mutating func resetScanDefaults() {
        let defaults = CaptureSettings()
        captureMode = defaults.captureMode
        scanAndGoIntervalSeconds = defaults.scanAndGoIntervalSeconds
        scanAndGoMinTranslationMeters = defaults.scanAndGoMinTranslationMeters
        scanAndGoMinRotationDegrees = defaults.scanAndGoMinRotationDegrees
        nearClipMeters = defaults.nearClipMeters
        farClipMeters = defaults.farClipMeters
        minDepthConfidence = defaults.minDepthConfidence
        spacingMode = defaults.spacingMode
        manualSpacingMeters = defaults.manualSpacingMeters
        maxPointBudget = defaults.maxPointBudget
    }
}
