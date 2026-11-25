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

enum LensOption: String, CaseIterable, Codable, Identifiable {
    case wide24mm = "24 mm (Wide)"
    case ultraWide13mmBeta = "13 mm (Ultra-Wide Beta)"

    var id: String { rawValue }

    /// ARKit ARWorldTrackingConfiguration with LiDAR sceneDepth only runs on the primary 24mm Wide lens.
    var isSupportedWithLiDARARKit: Bool {
        switch self {
        case .wide24mm: return true
        case .ultraWide13mmBeta: return false
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

enum ScanPreset: String, CaseIterable, Identifiable {
    case roomFast = "Room (Fast)"
    case objectDetail = "Object (High Detail)"
    case outdoorLarge = "Large Area"

    var id: String { rawValue }
}

struct CaptureSettings: Codable, Equatable {
    // Resolution & Lens
    var resolution: ResolutionPreset = .fullHD1080p
    var lens: LensOption = .wide24mm

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

    // Viewfinder Overlays
    var showLiveDepthPreview: Bool = false
    var showCoverageOverlay: Bool = false

    mutating func applyPreset(_ preset: ScanPreset) {
        switch preset {
        case .roomFast:
            spacingMode = .manual
            manualSpacingMeters = 0.02
            farClipMeters = 5.0
            scanAndGoIntervalSeconds = 0.4
            scanAndGoMinTranslationMeters = 0.15
            scanAndGoMinRotationDegrees = 10.0
        case .objectDetail:
            spacingMode = .manual
            manualSpacingMeters = 0.003
            farClipMeters = 2.5
            scanAndGoIntervalSeconds = 0.25
            scanAndGoMinTranslationMeters = 0.06
            scanAndGoMinRotationDegrees = 5.0
        case .outdoorLarge:
            spacingMode = .adaptive
            manualSpacingMeters = 0.035
            farClipMeters = 12.0
            scanAndGoIntervalSeconds = 0.5
            scanAndGoMinTranslationMeters = 0.25
            scanAndGoMinRotationDegrees = 12.0
        }
    }
}
