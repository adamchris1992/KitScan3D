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

enum ScanProfile: String, CaseIterable, Codable, Identifiable {
    case roomScene = "Room / Scene"
    case objectOrbit = "Object Orbit"

    var id: String { rawValue }
}

struct CaptureSettings: Codable, Equatable {
    // Resolution (always 4K for maximum texture detail)
    var resolution: ResolutionPreset = .uhd4K
    var profile: ScanProfile = .roomScene

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

    /// Applies Room/Scene or Object Orbit (max detail) scan settings.
    mutating func applyProfile(_ newProfile: ScanProfile) {
        profile = newProfile
        switch newProfile {
        case .roomScene:
            captureMode = .scanAndGo
            scanAndGoIntervalSeconds = 0.16
            scanAndGoMinTranslationMeters = 0.05
            scanAndGoMinRotationDegrees = 4.0
            nearClipMeters = 0.20
            farClipMeters = 5.00
            minDepthConfidence = 2
            spacingMode = .adaptive
            manualSpacingMeters = 0.005
            maxPointBudget = 3_000_000
        case .objectOrbit:
            captureMode = .scanAndGo
            scanAndGoIntervalSeconds = 0.10
            scanAndGoMinTranslationMeters = 0.025
            scanAndGoMinRotationDegrees = 2.5
            nearClipMeters = 0.20
            farClipMeters = 1.00
            minDepthConfidence = 2
            spacingMode = .manual
            manualSpacingMeters = 0.002
            maxPointBudget = 4_000_000
        }
    }

    /// Restores scan-quality defaults for the active profile while keeping exposure lock state.
    mutating func resetScanDefaults() {
        applyProfile(profile)
    }
}
