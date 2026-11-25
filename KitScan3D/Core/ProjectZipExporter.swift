import Foundation
import UIKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

enum ProjectZipExporter {
    struct Manifest: Codable {
        let schemaVersion: String
        let exportedAt: Date
        let deviceModel: String
        let coordinateSystem: String
        let units: String
        let depthScaleMetersPerUnit: Float
        let projectName: String
        let alignmentState: ProjectAlignmentState
        let scans: [ScanSessionMetadata]
    }

    /// Exports a portable `.zip` project bundle containing `manifest.json`, RGB images, 16-bit depth PNGs, poses JSON/CSV, and `merged_pointcloud.ply`.
    static func exportPortableBundle(project: ScanProjectMetadata, points: [PointVertex]) throws -> URL {
        let fm = FileManager.default
        let store = ScanProjectStore.shared
        let safeName = project.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let bundleRoot = store.projectDirectory(for: project.id).appendingPathComponent("exports/\(safeName)_Bundle", isDirectory: true)
        try? fm.removeItem(at: bundleRoot)
        try fm.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let alignment = store.loadAlignmentState(for: project.id)
        let scans = store.loadScans(for: project.id).sorted { $0.createdAt < $1.createdAt }

        let manifest = Manifest(
            schemaVersion: "1.0",
            exportedAt: Date(),
            deviceModel: UIDevice.current.model,
            coordinateSystem: "ARKit right-handed Y-up (-Z forward)",
            units: "meters",
            depthScaleMetersPerUnit: 0.001,
            projectName: project.name,
            alignmentState: alignment,
            scans: scans
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: bundleRoot.appendingPathComponent("manifest.json"), options: .atomic)

        try PLYExporter.exportBinaryPLY(points: points, to: bundleRoot.appendingPathComponent("merged_pointcloud.ply"))

        let decoder = JSONDecoder()
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601

        for scan in scans {
            let srcDir = store.scanDirectory(projectID: project.id, scanID: scan.id)
            let dstScanDir = bundleRoot.appendingPathComponent("scans/\(scan.id.uuidString)", isDirectory: true)
            let dstRGB = dstScanDir.appendingPathComponent("rgb", isDirectory: true)
            let dstDepth = dstScanDir.appendingPathComponent("depth", isDirectory: true)
            let dstConf = dstScanDir.appendingPathComponent("confidence", isDirectory: true)
            try fm.createDirectory(at: dstRGB, withIntermediateDirectories: true)
            try fm.createDirectory(at: dstDepth, withIntermediateDirectories: true)
            try fm.createDirectory(at: dstConf, withIntermediateDirectories: true)

            let jsonlURL = srcDir.appendingPathComponent("keyframes.jsonl")
            guard let content = try? String(contentsOf: jsonlURL, encoding: .utf8) else { continue }
            let refinedData = try? Data(contentsOf: store.refinedPosesURL(projectID: project.id, scanID: scan.id))
            let refinedPoses = refinedData.flatMap { try? isoDecoder.decode(RefinedScanPoses.self, from: $0) }
            let scanTransform = alignment.transform(for: scan.id)

            var poseRecords: [KeyframeRecord] = []
            var csvLines = ["index,timestamp,rgb,depth,confidence,width,height,fx,fy,cx,cy,m00,m01,m02,m03,m10,m11,m12,m13,m20,m21,m22,m23,m30,m31,m32,m33"]

            for line in content.split(separator: "\n") {
                autoreleasepool {
                    guard let lineData = line.data(using: .utf8),
                          let kf = try? decoder.decode(KeyframeRecord.self, from: lineData),
                          kf.intrinsics.count == 9, kf.transform.count == 16 else { return }

                    let srcImg = srcDir.appendingPathComponent("rgb/\(kf.rgbFilename)")
                    if fm.fileExists(atPath: srcImg.path) {
                        try? fm.copyItem(at: srcImg, to: dstRGB.appendingPathComponent(kf.rgbFilename))
                    }

                    let stem = String(format: "%06d", kf.index)
                    let depthPNGName = "\(stem)_depth.png"
                    let confPNGName = "\(stem)_conf.png"

                    if let depthData = try? Data(contentsOf: srcDir.appendingPathComponent("depth/\(kf.depthFilename)")) {
                        write16BitDepthPNG(depthData: depthData, width: kf.depthWidth, height: kf.depthHeight, to: dstDepth.appendingPathComponent(depthPNGName))
                    }
                    if let confData = try? Data(contentsOf: srcDir.appendingPathComponent("confidence/\(kf.confidenceFilename)")) {
                        write8BitGrayPNG(data: confData, width: kf.depthWidth, height: kf.depthHeight, to: dstConf.appendingPathComponent(confPNGName))
                    }

                    let poseArr = refinedPoses?.poses[kf.index] ?? kf.transform
                    let rawT = simd_float4x4(
                        SIMD4(poseArr[0], poseArr[1], poseArr[2], poseArr[3]),
                        SIMD4(poseArr[4], poseArr[5], poseArr[6], poseArr[7]),
                        SIMD4(poseArr[8], poseArr[9], poseArr[10], poseArr[11]),
                        SIMD4(poseArr[12], poseArr[13], poseArr[14], poseArr[15])
                    )
                    let worldT = scanTransform * rawT
                    let flatT: [Float] = [
                        worldT.columns.0.x, worldT.columns.0.y, worldT.columns.0.z, worldT.columns.0.w,
                        worldT.columns.1.x, worldT.columns.1.y, worldT.columns.1.z, worldT.columns.1.w,
                        worldT.columns.2.x, worldT.columns.2.y, worldT.columns.2.z, worldT.columns.2.w,
                        worldT.columns.3.x, worldT.columns.3.y, worldT.columns.3.z, worldT.columns.3.w
                    ]

                    let updated = KeyframeRecord(
                        index: kf.index,
                        timestamp: kf.timestamp,
                        rgbFilename: kf.rgbFilename,
                        depthFilename: depthPNGName,
                        confidenceFilename: confPNGName,
                        width: kf.width,
                        height: kf.height,
                        depthWidth: kf.depthWidth,
                        depthHeight: kf.depthHeight,
                        intrinsics: kf.intrinsics,
                        transform: flatT
                    )
                    poseRecords.append(updated)

                    let matStr = flatT.map { String(format: "%.6f", $0) }.joined(separator: ",")
                    csvLines.append(String(
                        format: "%d,%.6f,%@,%@,%@,%d,%d,%.3f,%.3f,%.3f,%.3f,%@",
                        kf.index, kf.timestamp, kf.rgbFilename, depthPNGName, confPNGName,
                        kf.width, kf.height, kf.intrinsics[0], kf.intrinsics[4], kf.intrinsics[6], kf.intrinsics[7], matStr
                    ))
                }
            }

            if let posesJSON = try? encoder.encode(poseRecords) {
                try? posesJSON.write(to: dstScanDir.appendingPathComponent("poses.json"), options: .atomic)
            }
            try? csvLines.joined(separator: "\n").appending("\n")
                .write(to: dstScanDir.appendingPathComponent("poses.csv"), atomically: true, encoding: .utf8)
        }

        let zipDest = store.projectDirectory(for: project.id).appendingPathComponent("exports/\(safeName)_Bundle.zip")
        try zipDirectory(at: bundleRoot, to: zipDest)
        DiagnosticsLogger.shared.log(.info, category: "Export", "Exported portable bundle -> \(zipDest.lastPathComponent)")
        return zipDest
    }

    static func zipDirectory(at sourceDir: URL, to destinationZip: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationZip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destinationZip)

        var coordError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: sourceDir, options: .forUploading, error: &coordError) { tempZipURL in
            do {
                try fm.copyItem(at: tempZipURL, to: destinationZip)
            } catch {
                copyError = error
            }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
    }

    private static func write16BitDepthPNG(depthData: Data, width: Int, height: Int, to url: URL) {
        var mmValues = [UInt16](repeating: 0, count: width * height)
        depthData.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float32.self)
            let count = min(floats.count, mmValues.count)
            for i in 0..<count {
                let d = floats[i]
                if d.isFinite && d > 0 {
                    mmValues[i] = UInt16(min(65535, max(0, Int(round(d * 1000.0)))))
                }
            }
        }
        let byteData = mmValues.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: byteData as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 16,
                bitsPerPixel: 16,
                bytesPerRow: width * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func write8BitGrayPNG(data: Data, width: Int, height: Int, to url: URL) {
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }
}
