import Foundation
import CoreVideo
import CoreImage
import simd

struct ScanProjectMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var scanIDs: [UUID]
}

struct ScanSessionMetadata: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    var frameCount: Int
    var resolutionWidth: Int
    var resolutionHeight: Int
}

struct KeyframeRecord: Codable {
    let index: Int
    let timestamp: TimeInterval
    let rgbFilename: String
    let depthFilename: String
    let confidenceFilename: String
    let width: Int
    let height: Int
    let depthWidth: Int
    let depthHeight: Int
    let intrinsics: [Float] // 3x3 column-major (9 floats)
    let transform: [Float]  // 4x4 column-major (16 floats)
}

struct CropBox3D: Codable, Equatable {
    var isEnabled: Bool = false
    var centerX: Float = 0
    var centerY: Float = 0
    var centerZ: Float = 0
    var sizeX: Float = 4.0
    var sizeY: Float = 3.0
    var sizeZ: Float = 4.0
    var yawDegrees: Float = 0

    var center: SIMD3<Float> {
        SIMD3<Float>(centerX, centerY, centerZ)
    }

    var halfExtents: SIMD3<Float> {
        SIMD3<Float>(max(0.1, sizeX * 0.5), max(0.1, sizeY * 0.5), max(0.1, sizeZ * 0.5))
    }

    func contains(_ p: SIMD3<Float>) -> Bool {
        guard isEnabled else { return true }
        let d = p - center
        let rad = -yawDegrees * (.pi / 180.0)
        let c = cos(rad)
        let s = sin(rad)
        let lx = d.x * c - d.z * s
        let lz = d.x * s + d.z * c
        let h = halfExtents
        return abs(lx) <= h.x && abs(d.y) <= h.y && abs(lz) <= h.z
    }
}

struct ProjectAlignmentState: Codable, Equatable {
    /// Per-scan 4x4 column-major alignment transform (identity if absent).
    var scanTransforms: [String: [Float]] = [:]
    /// Scan IDs hidden by the user in the 3D viewer.
    var hiddenScanIDs: [String] = []
    /// Interactive 3D crop box.
    var cropBox: CropBox3D = CropBox3D()

    func transform(for scanID: UUID) -> simd_float4x4 {
        guard let arr = scanTransforms[scanID.uuidString], arr.count == 16 else {
            return matrix_identity_float4x4
        }
        return simd_float4x4(
            SIMD4(arr[0], arr[1], arr[2], arr[3]),
            SIMD4(arr[4], arr[5], arr[6], arr[7]),
            SIMD4(arr[8], arr[9], arr[10], arr[11]),
            SIMD4(arr[12], arr[13], arr[14], arr[15])
        )
    }

    mutating func setTransform(_ m: simd_float4x4, for scanID: UUID) {
        scanTransforms[scanID.uuidString] = [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
        ]
    }
}

/// Manages scan project directories in Documents/Projects/ and writes keyframes on a bounded background queue.
/// All public methods are expected to be called from the main thread.
final class ScanProjectStore: ObservableObject {
    static let shared = ScanProjectStore()

    @Published private(set) var projects: [ScanProjectMetadata] = []
    @Published private(set) var pendingWriteCount: Int = 0

    let projectsRootURL: URL
    private let writeQueue: OperationQueue
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let maxPendingWrites = 18

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.projectsRootURL = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)

        self.writeQueue = OperationQueue()
        self.writeQueue.name = "com.kitscan3d.diskwriter"
        self.writeQueue.maxConcurrentOperationCount = 4
        self.writeQueue.qualityOfService = .userInitiated

        reloadProjects()
    }

    // MARK: - Projects

    func reloadProjects() {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: projectsRootURL, includingPropertiesForKeys: nil) else {
            return
        }
        let decoder = Self.makeDecoder()
        let loaded = contents
            .filter(\.hasDirectoryPath)
            .compactMap { dir -> ScanProjectMetadata? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("project.json")) else { return nil }
                return try? decoder.decode(ScanProjectMetadata.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        projects = loaded
    }

    func project(id: UUID) -> ScanProjectMetadata? {
        projects.first { $0.id == id }
    }

    @discardableResult
    func createProject(name: String) -> ScanProjectMetadata {
        let now = Date()
        let project = ScanProjectMetadata(
            id: UUID(),
            name: name.isEmpty ? "Scan Project" : name,
            createdAt: now,
            updatedAt: now,
            scanIDs: []
        )
        try? FileManager.default.createDirectory(
            at: projectDirectory(for: project.id).appendingPathComponent("scans", isDirectory: true),
            withIntermediateDirectories: true
        )
        saveProjectMetadata(project)
        projects.insert(project, at: 0)
        DiagnosticsLogger.shared.log(.info, category: "Store", "Created project '\(project.name)' (\(project.id.uuidString.prefix(8)))")
        return project
    }

    func renameProject(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var project = project(id: id) else { return }
        project.name = trimmed
        project.updatedAt = Date()
        commit(project)
        DiagnosticsLogger.shared.log(.info, category: "Store", "Renamed project \(id.uuidString.prefix(8)) to '\(trimmed)'")
    }

    func deleteProject(id: UUID) {
        try? FileManager.default.removeItem(at: projectDirectory(for: id))
        projects.removeAll { $0.id == id }
        DiagnosticsLogger.shared.log(.info, category: "Store", "Deleted project \(id.uuidString.prefix(8))")
    }

    // MARK: - Scans

    func beginNewScanSession(projectID: UUID, width: Int, height: Int) -> ScanSessionMetadata? {
        guard var project = project(id: projectID) else { return nil }

        let scan = ScanSessionMetadata(
            id: UUID(),
            name: "Pass \(loadScans(for: projectID).count + 1)",
            createdAt: Date(),
            frameCount: 0,
            resolutionWidth: width,
            resolutionHeight: height
        )

        let scanDir = scanDirectory(projectID: projectID, scanID: scan.id)
        for sub in ["rgb", "depth", "confidence"] {
            try? FileManager.default.createDirectory(at: scanDir.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        saveScanMetadata(scan, projectID: projectID)

        project.scanIDs.append(scan.id)
        project.updatedAt = Date()
        commit(project)

        DiagnosticsLogger.shared.log(.info, category: "Store", "Started scan session \(scan.id.uuidString.prefix(8)) in project '\(project.name)'")
        return scan
    }

    func updateScanStats(projectID: UUID, scan: ScanSessionMetadata) {
        saveScanMetadata(scan, projectID: projectID)
    }

    func deleteScan(projectID: UUID, scanID: UUID) {
        try? FileManager.default.removeItem(at: scanDirectory(projectID: projectID, scanID: scanID))
        if var project = project(id: projectID) {
            project.scanIDs.removeAll { $0 == scanID }
            project.updatedAt = Date()
            commit(project)
        }
        DiagnosticsLogger.shared.log(.info, category: "Store", "Deleted scan \(scanID.uuidString.prefix(8))")
    }

    /// Returns passes for a project, newest first.
    func loadScans(for projectID: UUID) -> [ScanSessionMetadata] {
        let scansDir = projectDirectory(for: projectID).appendingPathComponent("scans", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: scansDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = Self.makeDecoder()
        return dirs
            .filter(\.hasDirectoryPath)
            .compactMap { dir -> ScanSessionMetadata? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("scan.json")) else { return nil }
                return try? decoder.decode(ScanSessionMetadata.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Keyframe Writing

    /// Enqueues an RGB-D keyframe to disk asynchronously. Drops gracefully if the disk queue is saturated.
    func enqueueKeyframeWrite(
        projectID: UUID,
        scanID: UUID,
        frameIndex: Int,
        timestamp: TimeInterval,
        rgbBuffer: CVPixelBuffer,
        depthBuffer: CVPixelBuffer,
        confidenceBuffer: CVPixelBuffer?,
        intrinsics: simd_float3x3,
        transform: simd_float4x4
    ) -> Bool {
        if writeQueue.operationCount >= maxPendingWrites {
            DiagnosticsLogger.shared.log(.warning, category: "Store", "Disk write queue saturated (\(writeQueue.operationCount)); dropping keyframe \(frameIndex)")
            return false
        }

        let scanDir = scanDirectory(projectID: projectID, scanID: scanID)
        let rgbWidth = CVPixelBufferGetWidth(rgbBuffer)
        let rgbHeight = CVPixelBufferGetHeight(rgbBuffer)
        let depthWidth = CVPixelBufferGetWidth(depthBuffer)
        let depthHeight = CVPixelBufferGetHeight(depthBuffer)

        // Copy raw buffers quickly on caller thread so the ARFrame can be released immediately
        guard let depthData = Self.copyTightPixelBytes(depthBuffer) else { return false }
        let confData = confidenceBuffer.flatMap { Self.copyTightPixelBytes($0) }
        let ciImage = CIImage(cvPixelBuffer: rgbBuffer)

        pendingWriteCount = writeQueue.operationCount + 1

        writeQueue.addOperation { [weak self] in
            guard let self else { return }
            defer {
                DispatchQueue.main.async {
                    self.pendingWriteCount = self.writeQueue.operationCount
                }
            }

            let stem = String(format: "%06d", frameIndex)
            let rgbName = "\(stem).jpg"
            let depthName = "\(stem).depth.bin"
            let confName = "\(stem).conf.bin"

            if let jpegData = self.ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88]
            ) {
                try? jpegData.write(to: scanDir.appendingPathComponent("rgb/\(rgbName)"), options: .atomic)
            }
            try? depthData.write(to: scanDir.appendingPathComponent("depth/\(depthName)"), options: .atomic)
            if let confData {
                try? confData.write(to: scanDir.appendingPathComponent("confidence/\(confName)"), options: .atomic)
            }

            let record = KeyframeRecord(
                index: frameIndex,
                timestamp: timestamp,
                rgbFilename: rgbName,
                depthFilename: depthName,
                confidenceFilename: confName,
                width: rgbWidth,
                height: rgbHeight,
                depthWidth: depthWidth,
                depthHeight: depthHeight,
                intrinsics: Self.flatten(intrinsics),
                transform: Self.flatten(transform)
            )
            Self.appendJSONLine(record, to: scanDir.appendingPathComponent("keyframes.jsonl"))
        }

        return true
    }

    // MARK: - Paths

    func projectDirectory(for projectID: UUID) -> URL {
        projectsRootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    func scanDirectory(projectID: UUID, scanID: UUID) -> URL {
        projectDirectory(for: projectID).appendingPathComponent("scans/\(scanID.uuidString)", isDirectory: true)
    }

    func worldMapURL(for projectID: UUID) -> URL {
        projectDirectory(for: projectID).appendingPathComponent("worldmap.arexperience")
    }

    func loadAlignmentState(for projectID: UUID) -> ProjectAlignmentState {
        let url = projectDirectory(for: projectID).appendingPathComponent("alignment.json")
        guard let data = try? Data(contentsOf: url),
              let state = try? Self.makeDecoder().decode(ProjectAlignmentState.self, from: data) else {
            return ProjectAlignmentState()
        }
        return state
    }

    func saveAlignmentState(_ state: ProjectAlignmentState, for projectID: UUID) {
        let url = projectDirectory(for: projectID).appendingPathComponent("alignment.json")
        if let data = try? Self.makeEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func refinedPosesURL(projectID: UUID, scanID: UUID) -> URL {
        scanDirectory(projectID: projectID, scanID: scanID).appendingPathComponent("refined_poses.json")
    }

    // MARK: - Private Helpers

    private func commit(_ project: ScanProjectMetadata) {
        saveProjectMetadata(project)
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        }
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    private func saveProjectMetadata(_ project: ScanProjectMetadata) {
        let url = projectDirectory(for: project.id).appendingPathComponent("project.json")
        if let data = try? Self.makeEncoder().encode(project) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveScanMetadata(_ scan: ScanSessionMetadata, projectID: UUID) {
        let url = scanDirectory(projectID: projectID, scanID: scan.id).appendingPathComponent("scan.json")
        if let data = try? Self.makeEncoder().encode(scan) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func appendJSONLine<T: Encodable>(_ value: T, to url: URL) {
        guard var line = try? JSONEncoder().encode(value) else { return }
        line.append(0x0A) // "\n"
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// Copies pixel data without CVPixelBuffer row padding so rows can be indexed as `y * width + x`.
    private static func copyTightPixelBytes(_ buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        let bytesPerPixel = (pixelFormat == kCVPixelFormatType_DepthFloat32 || pixelFormat == kCVPixelFormatType_DisparityFloat32) ? 4 : 1
        let tightRowBytes = width * bytesPerPixel

        if bytesPerRow == tightRowBytes {
            return Data(bytes: base, count: tightRowBytes * height)
        }
        var tightData = Data(capacity: tightRowBytes * height)
        for y in 0..<height {
            tightData.append(base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self), count: tightRowBytes)
        }
        return tightData
    }

    private static func flatten(_ m: simd_float3x3) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z,
         m.columns.1.x, m.columns.1.y, m.columns.1.z,
         m.columns.2.x, m.columns.2.y, m.columns.2.z]
    }

    private static func flatten(_ m: simd_float4x4) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
         m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
         m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
         m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }
}
