import Foundation
import CoreVideo
import CoreImage
import UIKit
import simd

struct ScanProjectMetadata: Codable, Identifiable {
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
    var pointCount: Int
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

/// Manages non-destructive scan project directories in Documents/Projects/ and writes keyframes on a bounded background queue.
final class ScanProjectStore: ObservableObject {
    static let shared = ScanProjectStore()

    @Published private(set) var projects: [ScanProjectMetadata] = []
    @Published private(set) var activeProject: ScanProjectMetadata?
    @Published private(set) var pendingWriteCount: Int = 0

    let projectsRootURL: URL
    private let writeQueue: OperationQueue
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let maxPendingWrites = 6

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.projectsRootURL = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)

        self.writeQueue = OperationQueue()
        self.writeQueue.name = "com.kitscan3d.diskwriter"
        self.writeQueue.maxConcurrentOperationCount = 2
        self.writeQueue.qualityOfService = .userInitiated

        reloadProjects()
    }

    func reloadProjects() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: projectsRootURL, includingPropertiesForKeys: nil) else {
            return
        }

        var loaded: [ScanProjectMetadata] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for dir in contents where dir.hasDirectoryPath {
            let metaURL = dir.appendingPathComponent("project.json")
            if let data = try? Data(contentsOf: metaURL),
               let meta = try? decoder.decode(ScanProjectMetadata.self, from: data) {
                loaded.append(meta)
            }
        }

        loaded.sort { $0.updatedAt > $1.updatedAt }
        DispatchQueue.main.async {
            self.projects = loaded
            if self.activeProject == nil {
                self.activeProject = loaded.first
            }
        }
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
        let dir = projectDirectory(for: project.id)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("scans", isDirectory: true), withIntermediateDirectories: true)
        saveProjectMetadata(project)

        DispatchQueue.main.async {
            self.projects.insert(project, at: 0)
            self.activeProject = project
        }
        DiagnosticsLogger.shared.log(.info, category: "Store", "Created project '\(project.name)' (\(project.id.uuidString.prefix(8)))")
        return project
    }

    func ensureActiveProject() -> ScanProjectMetadata {
        if let active = activeProject {
            return active
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return createProject(name: "Scan \(formatter.string(from: Date()))")
    }

    func beginNewScanSession(in project: ScanProjectMetadata, width: Int, height: Int) -> ScanSessionMetadata {
        let scan = ScanSessionMetadata(
            id: UUID(),
            name: "Pass \(project.scanIDs.count + 1)",
            createdAt: Date(),
            frameCount: 0,
            pointCount: 0,
            resolutionWidth: width,
            resolutionHeight: height
        )

        let scanDir = scanDirectory(projectID: project.id, scanID: scan.id)
        let fm = FileManager.default
        try? fm.createDirectory(at: scanDir.appendingPathComponent("rgb", isDirectory: true), withIntermediateDirectories: true)
        try? fm.createDirectory(at: scanDir.appendingPathComponent("depth", isDirectory: true), withIntermediateDirectories: true)
        try? fm.createDirectory(at: scanDir.appendingPathComponent("confidence", isDirectory: true), withIntermediateDirectories: true)
        saveScanMetadata(scan, projectID: project.id)

        var updatedProject = project
        updatedProject.scanIDs.append(scan.id)
        updatedProject.updatedAt = Date()
        saveProjectMetadata(updatedProject)

        DispatchQueue.main.async {
            self.activeProject = updatedProject
            if let idx = self.projects.firstIndex(where: { $0.id == updatedProject.id }) {
                self.projects[idx] = updatedProject
            }
        }
        DiagnosticsLogger.shared.log(.info, category: "Store", "Started scan session \(scan.id.uuidString.prefix(8)) in project '\(updatedProject.name)'")
        return scan
    }

    /// Enqueues an RGB-D keyframe to disk asynchronously. Drops gracefully if disk queue is saturated.
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

        // Copy raw buffers quickly on caller thread so ARFrame can be released immediately
        guard let depthData = copyPixelBufferRawBytes(depthBuffer) else { return false }
        let confData = confidenceBuffer.flatMap { copyPixelBufferRawBytes($0) }
        let ciImage = CIImage(cvPixelBuffer: rgbBuffer)

        DispatchQueue.main.async {
            self.pendingWriteCount = self.writeQueue.operationCount + 1
        }

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

            let rgbURL = scanDir.appendingPathComponent("rgb/\(rgbName)")
            let depthURL = scanDir.appendingPathComponent("depth/\(depthName)")
            let confURL = scanDir.appendingPathComponent("confidence/\(confName)")

            if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                let uiImage = UIImage(cgImage: cgImage)
                if let jpegData = uiImage.jpegData(compressionQuality: 0.92) {
                    try? jpegData.write(to: rgbURL, options: .atomic)
                }
            }

            try? depthData.write(to: depthURL, options: .atomic)
            if let confData {
                try? confData.write(to: confURL, options: .atomic)
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

            let jsonlURL = scanDir.appendingPathComponent("keyframes.jsonl")
            let encoder = JSONEncoder()
            if let lineData = try? encoder.encode(record),
               var line = String(data: lineData, encoding: .utf8) {
                line.append("\n")
                if let out = line.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: jsonlURL.path),
                       let handle = try? FileHandle(forWritingTo: jsonlURL) {
                        defer { try? handle.close() }
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: out)
                    } else {
                        try? out.write(to: jsonlURL, options: .atomic)
                    }
                }
            }
        }

        return true
    }

    func updateScanStats(projectID: UUID, scan: ScanSessionMetadata) {
        saveScanMetadata(scan, projectID: projectID)
    }

    func renameProject(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var project = projects.first(where: { $0.id == id }) else { return }
        project.name = trimmed
        project.updatedAt = Date()
        saveProjectMetadata(project)

        DispatchQueue.main.async {
            if let idx = self.projects.firstIndex(where: { $0.id == id }) {
                self.projects[idx] = project
                self.projects.sort { $0.updatedAt > $1.updatedAt }
            }
            if self.activeProject?.id == id {
                self.activeProject = project
            }
        }
        DiagnosticsLogger.shared.log(.info, category: "Store", "Renamed project \(id.uuidString.prefix(8)) to '\(trimmed)'")
    }

    func deleteProject(id: UUID) {
        let dir = projectDirectory(for: id)
        try? FileManager.default.removeItem(at: dir)
        DispatchQueue.main.async {
            self.projects.removeAll { $0.id == id }
            if self.activeProject?.id == id {
                self.activeProject = self.projects.first
            }
        }
        DiagnosticsLogger.shared.log(.info, category: "Store", "Deleted project \(id.uuidString.prefix(8))")
    }

    func deleteScan(projectID: UUID, scanID: UUID) {
        let dir = scanDirectory(projectID: projectID, scanID: scanID)
        try? FileManager.default.removeItem(at: dir)
        if var project = projects.first(where: { $0.id == projectID }) {
            project.scanIDs.removeAll { $0 == scanID }
            project.updatedAt = Date()
            saveProjectMetadata(project)
            DispatchQueue.main.async {
                if let idx = self.projects.firstIndex(where: { $0.id == projectID }) {
                    self.projects[idx] = project
                }
            }
        }
        DiagnosticsLogger.shared.log(.info, category: "Store", "Deleted scan \(scanID.uuidString.prefix(8))")
    }

    func loadScans(for projectID: UUID) -> [ScanSessionMetadata] {
        let scansDir = projectDirectory(for: projectID).appendingPathComponent("scans", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: scansDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [ScanSessionMetadata] = []
        for dir in dirs where dir.hasDirectoryPath {
            let metaURL = dir.appendingPathComponent("scan.json")
            if let data = try? Data(contentsOf: metaURL),
               let meta = try? decoder.decode(ScanSessionMetadata.self, from: data) {
                result.append(meta)
            }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    func projectDirectory(for projectID: UUID) -> URL {
        projectsRootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    func scanDirectory(projectID: UUID, scanID: UUID) -> URL {
        projectDirectory(for: projectID).appendingPathComponent("scans/\(scanID.uuidString)", isDirectory: true)
    }

    private func saveProjectMetadata(_ project: ScanProjectMetadata) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = projectDirectory(for: project.id).appendingPathComponent("project.json")
        if let data = try? encoder.encode(project) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func saveScanMetadata(_ scan: ScanSessionMetadata, projectID: UUID) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = scanDirectory(projectID: projectID, scanID: scan.id).appendingPathComponent("scan.json")
        if let data = try? encoder.encode(scan) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func copyPixelBufferRawBytes(_ buffer: CVPixelBuffer) -> Data? {
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
            let rowPtr = base.advanced(by: y * bytesPerRow)
            tightData.append(rowPtr.assumingMemoryBound(to: UInt8.self), count: tightRowBytes)
        }
        return tightData
    }

    private static func flatten(_ m: simd_float3x3) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z,
            m.columns.1.x, m.columns.1.y, m.columns.1.z,
            m.columns.2.x, m.columns.2.y, m.columns.2.z
        ]
    }

    private static func flatten(_ m: simd_float4x4) -> [Float] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
        ]
    }
}
