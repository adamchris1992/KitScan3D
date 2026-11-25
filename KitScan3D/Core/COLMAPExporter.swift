import Foundation
import simd

enum COLMAPDensity: String, CaseIterable, Identifiable {
    case sparse = "Sparse (~25K)"
    case downsampled = "Downsampled (~250K)"
    case full = "Full Dense"

    var id: String { rawValue }

    var maxPoints: Int {
        switch self {
        case .sparse: return 25_000
        case .downsampled: return 250_000
        case .full: return Int.max
        }
    }
}

enum COLMAPExporter {
    struct Extrinsics {
        let qw: Float
        let qx: Float
        let qy: Float
        let qz: Float
        let tx: Float
        let ty: Float
        let tz: Float
    }

    /// Converts an ARKit camera-to-world transform (+X right, +Y up, -Z forward)
    /// into COLMAP world-to-camera extrinsics (+X right, +Y down, +Z forward).
    static func arkitToCOLMAPExtrinsics(_ c2wARKit: simd_float4x4) -> Extrinsics {
        let flipYZ = simd_float4x4(diagonal: SIMD4<Float>(1, -1, -1, 1))
        let c2wCOLMAP = c2wARKit * flipYZ
        let w2c = c2wCOLMAP.inverse

        let r = simd_float3x3(
            SIMD3(w2c.columns.0.x, w2c.columns.0.y, w2c.columns.0.z),
            SIMD3(w2c.columns.1.x, w2c.columns.1.y, w2c.columns.1.z),
            SIMD3(w2c.columns.2.x, w2c.columns.2.y, w2c.columns.2.z)
        )
        let q = simd_quatf(r)
        let t = SIMD3<Float>(w2c.columns.3.x, w2c.columns.3.y, w2c.columns.3.z)
        return Extrinsics(qw: q.real, qx: q.imag.x, qy: q.imag.y, qz: q.imag.z, tx: t.x, ty: t.y, tz: t.z)
    }

    /// Exports a standard COLMAP dataset (`images/`, `sparse/0/{cameras,images,points3D}.txt`, `points3D.ply`) and zips it.
    static func exportCOLMAPZip(
        project: ScanProjectMetadata,
        points: [PointVertex],
        density: COLMAPDensity
    ) throws -> URL {
        let fm = FileManager.default
        let store = ScanProjectStore.shared
        let safeName = project.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let exportRoot = store.projectDirectory(for: project.id).appendingPathComponent("exports/COLMAP_\(safeName)", isDirectory: true)
        let imagesDir = exportRoot.appendingPathComponent("images", isDirectory: true)
        let sparseDir = exportRoot.appendingPathComponent("sparse/0", isDirectory: true)

        try? fm.removeItem(at: exportRoot)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sparseDir, withIntermediateDirectories: true)

        let alignment = store.loadAlignmentState(for: project.id)
        let hidden = Set(alignment.hiddenScanIDs)
        let scans = store.loadScans(for: project.id)
            .filter { !hidden.contains($0.id.uuidString) }
            .sorted { $0.createdAt < $1.createdAt }

        let decoder = JSONDecoder()
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601

        struct CameraKey: Hashable {
            let width: Int
            let height: Int
            let fx: Int
            let fy: Int
            let cx: Int
            let cy: Int
        }

        var cameraIDMap: [CameraKey: Int] = [:]
        var camerasLines: [String] = [
            "# Camera list with one line of data per camera:",
            "#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]"
        ]
        var imagesLines: [String] = [
            "# Image list with two lines of data per image:",
            "#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME",
            "#   POINTS2D[] as (X, Y, POINT3D_ID)"
        ]

        var nextCameraID = 1
        var nextImageID = 1

        for (scanIdx, scan) in scans.enumerated() {
            let scanDir = store.scanDirectory(projectID: project.id, scanID: scan.id)
            let jsonlURL = scanDir.appendingPathComponent("keyframes.jsonl")
            guard let content = try? String(contentsOf: jsonlURL, encoding: .utf8) else { continue }

            let refinedData = try? Data(contentsOf: store.refinedPosesURL(projectID: project.id, scanID: scan.id))
            let refinedPoses = refinedData.flatMap { try? isoDecoder.decode(RefinedScanPoses.self, from: $0) }
            let scanTransform = alignment.transform(for: scan.id)

            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let kf = try? decoder.decode(KeyframeRecord.self, from: data),
                      kf.intrinsics.count == 9, kf.transform.count == 16 else { continue }

                let fx = kf.intrinsics[0]
                let fy = kf.intrinsics[4]
                let cx = kf.intrinsics[6]
                let cy = kf.intrinsics[7]
                let camKey = CameraKey(
                    width: kf.width,
                    height: kf.height,
                    fx: Int(round(fx * 10)),
                    fy: Int(round(fy * 10)),
                    cx: Int(round(cx * 10)),
                    cy: Int(round(cy * 10))
                )

                let camID: Int
                if let existing = cameraIDMap[camKey] {
                    camID = existing
                } else {
                    camID = nextCameraID
                    nextCameraID += 1
                    cameraIDMap[camKey] = camID
                    camerasLines.append(String(format: "%d PINHOLE %d %d %.4f %.4f %.4f %.4f", camID, kf.width, kf.height, fx, fy, cx, cy))
                }

                let poseArr = refinedPoses?.poses[kf.index] ?? kf.transform
                let rawPose = simd_float4x4(
                    SIMD4(poseArr[0], poseArr[1], poseArr[2], poseArr[3]),
                    SIMD4(poseArr[4], poseArr[5], poseArr[6], poseArr[7]),
                    SIMD4(poseArr[8], poseArr[9], poseArr[10], poseArr[11]),
                    SIMD4(poseArr[12], poseArr[13], poseArr[14], poseArr[15])
                )
                let worldPose = scanTransform * rawPose
                let ext = arkitToCOLMAPExtrinsics(worldPose)

                let outImgName = String(format: "s%02d_%@", scanIdx + 1, kf.rgbFilename)
                let srcImgURL = scanDir.appendingPathComponent("rgb/\(kf.rgbFilename)")
                let dstImgURL = imagesDir.appendingPathComponent(outImgName)
                if fm.fileExists(atPath: srcImgURL.path) {
                    try? fm.copyItem(at: srcImgURL, to: dstImgURL)
                }

                imagesLines.append(String(
                    format: "%d %.6f %.6f %.6f %.6f %.6f %.6f %.6f %d %@",
                    nextImageID, ext.qw, ext.qx, ext.qy, ext.qz, ext.tx, ext.ty, ext.tz, camID, outImgName
                ))
                imagesLines.append("") // Empty 2D points line required by COLMAP format
                nextImageID += 1
            }
        }

        try camerasLines.joined(separator: "\n").appending("\n")
            .write(to: sparseDir.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try imagesLines.joined(separator: "\n").appending("\n")
            .write(to: sparseDir.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)

        // Subsample points according to chosen COLMAP density
        let sampledPoints = subsamplePoints(points, maxCount: density.maxPoints)
        var ptsLines: [String] = [
            "# 3D point list with one line of data per point:",
            "#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)"
        ]
        ptsLines.reserveCapacity(sampledPoints.count + 2)
        for (idx, pt) in sampledPoints.enumerated() {
            let r = UInt8(max(0, min(255, Int(round(pt.color.0 * 255.0)))))
            let g = UInt8(max(0, min(255, Int(round(pt.color.1 * 255.0)))))
            let b = UInt8(max(0, min(255, Int(round(pt.color.2 * 255.0)))))
            ptsLines.append(String(format: "%d %.5f %.5f %.5f %d %d %d 0.0", idx + 1, pt.position.0, pt.position.1, pt.position.2, r, g, b))
        }
        try ptsLines.joined(separator: "\n").appending("\n")
            .write(to: sparseDir.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

        try PLYExporter.exportBinaryPLY(points: sampledPoints, to: sparseDir.appendingPathComponent("points3D.ply"))

        let zipDest = store.projectDirectory(for: project.id).appendingPathComponent("exports/\(safeName)_COLMAP.zip")
        try ProjectZipExporter.zipDirectory(at: exportRoot, to: zipDest)
        DiagnosticsLogger.shared.log(.info, category: "Export", "COLMAP (\(density.rawValue)): \(nextImageID - 1) images, \(sampledPoints.count) points -> \(zipDest.lastPathComponent)")
        return zipDest
    }

    private static func subsamplePoints(_ points: [PointVertex], maxCount: Int) -> [PointVertex] {
        guard points.count > maxCount, maxCount > 0 else { return points }
        let step = max(1, points.count / maxCount)
        var out: [PointVertex] = []
        out.reserveCapacity(maxCount)
        for i in Swift.stride(from: 0, to: points.count, by: step) {
            out.append(points[i])
        }
        return out
    }
}
