import Foundation
import Accelerate
import simd

struct ICPResult {
    let transform: simd_float4x4
    let rmse: Float
    let inlierCount: Int
}

struct RefinedScanPoses: Codable {
    let scanID: UUID
    let updatedAt: Date
    /// Keyframe index -> 4x4 column-major transform (16 floats).
    var poses: [Int: [Float]]
}

enum PointCloudRegistration {
    /// Builds a rigid transform from translation (meters) and Y-axis yaw (degrees).
    static func makeTransform(translation: SIMD3<Float>, yawDegrees: Float) -> simd_float4x4 {
        let rad = yawDegrees * (.pi / 180.0)
        let c = cos(rad)
        let s = sin(rad)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(c, 0, -s, 0)
        m.columns.1 = SIMD4<Float>(0, 1, 0, 0)
        m.columns.2 = SIMD4<Float>(s, 0, c, 0)
        m.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return m
    }

    /// Extracts (translation, yawDegrees) from a 4x4 transform.
    static func decompose(_ m: simd_float4x4) -> (translation: SIMD3<Float>, yawDegrees: Float) {
        let t = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let yawRad = atan2(m.columns.0.z, m.columns.0.x)
        return (t, -yawRad * (180.0 / .pi))
    }

    /// Fast spatial-hash accelerated Point-to-Point ICP using Kabsch SVD via Accelerate.
    static func alignICP(
        source: [SIMD3<Float>],
        target: [SIMD3<Float>],
        initialTransform: simd_float4x4 = matrix_identity_float4x4,
        iterations: Int = 24,
        maxDistance: Float = 0.20
    ) -> ICPResult {
        let srcSample = subsample(source, maxCount: 2400)
        let tgtSample = subsample(target, maxCount: 4000)
        guard srcSample.count >= 16, tgtSample.count >= 16 else {
            return ICPResult(transform: initialTransform, rmse: 0, inlierCount: 0)
        }

        let cellSize = max(0.05, maxDistance)
        var grid: [Int64: [SIMD3<Float>]] = [:]
        grid.reserveCapacity(tgtSample.count)
        for p in tgtSample {
            let key = VoxelHash.key(for: p, spacing: cellSize)
            grid[key, default: []].append(p)
        }

        var current = initialTransform
        var lastRMSE: Float = 0
        var lastInliers = 0

        for iter in 0..<iterations {
            // Coarse-to-fine correspondence radius
            let thresh = iter < iterations / 2 ? maxDistance : max(0.04, maxDistance * 0.45)
            let threshSq = thresh * thresh

            var matchedSrc: [SIMD3<Float>] = []
            var matchedTgt: [SIMD3<Float>] = []
            matchedSrc.reserveCapacity(srcSample.count)
            matchedTgt.reserveCapacity(srcSample.count)
            var sumSq: Float = 0

            for p in srcSample {
                let wp4 = current * SIMD4<Float>(p, 1.0)
                let wp = SIMD3<Float>(wp4.x, wp4.y, wp4.z)
                if let nn = nearestNeighbor(to: wp, in: grid, cellSize: cellSize, maxDistSq: threshSq) {
                    matchedSrc.append(wp)
                    matchedTgt.append(nn.point)
                    sumSq += nn.distSq
                }
            }

            guard matchedSrc.count >= 12 else { break }
            lastInliers = matchedSrc.count
            lastRMSE = sqrt(sumSq / Float(matchedSrc.count))

            let delta = kabschRigidTransform(from: matchedSrc, to: matchedTgt)
            current = delta * current

            // Early convergence check
            let dTrans = simd_length(SIMD3<Float>(delta.columns.3.x, delta.columns.3.y, delta.columns.3.z))
            if dTrans < 0.0005 && iter > 6 {
                break
            }
        }

        return ICPResult(transform: current, rmse: lastRMSE, inlierCount: lastInliers)
    }

    /// Runs sliding-window ICP across a scan's keyframes to tighten drift and saves non-destructive `refined_poses.json`.
    static func refineScanPoses(
        projectID: UUID,
        scanID: UUID,
        settings: CaptureSettings,
        completion: @escaping (Int) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let store = ScanProjectStore.shared
            let scanDir = store.scanDirectory(projectID: projectID, scanID: scanID)
            let jsonlURL = scanDir.appendingPathComponent("keyframes.jsonl")
            guard let content = try? String(contentsOf: jsonlURL, encoding: .utf8) else {
                DispatchQueue.main.async { completion(0) }
                return
            }

            let decoder = JSONDecoder()
            var records: [KeyframeRecord] = []
            for line in content.split(separator: "\n") {
                if let data = line.data(using: .utf8),
                   let kf = try? decoder.decode(KeyframeRecord.self, from: data),
                   kf.transform.count == 16, kf.intrinsics.count == 9 {
                    records.append(kf)
                }
            }

            guard records.count >= 2 else {
                DispatchQueue.main.async { completion(0) }
                return
            }

            var modelPoints: [SIMD3<Float>] = []
            var refinedMap: [Int: [Float]] = [:]

            for (idx, kf) in records.enumerated() {
                let rawT = simd_float4x4(
                    SIMD4(kf.transform[0], kf.transform[1], kf.transform[2], kf.transform[3]),
                    SIMD4(kf.transform[4], kf.transform[5], kf.transform[6], kf.transform[7]),
                    SIMD4(kf.transform[8], kf.transform[9], kf.transform[10], kf.transform[11]),
                    SIMD4(kf.transform[12], kf.transform[13], kf.transform[14], kf.transform[15])
                )

                let depthURL = scanDir.appendingPathComponent("depth/\(kf.depthFilename)")
                guard let depthData = try? Data(contentsOf: depthURL) else { continue }
                let localPts = sampleLocalPoints(
                    depthData: depthData,
                    kf: kf,
                    nearClip: settings.nearClipMeters,
                    farClip: settings.farClipMeters
                )

                var finalT = rawT
                if idx > 0 && modelPoints.count >= 64 && localPts.count >= 32 {
                    let res = alignICP(
                        source: localPts,
                        target: modelPoints,
                        initialTransform: rawT,
                        iterations: 10,
                        maxDistance: 0.10
                    )
                    if res.inlierCount >= 24 && res.rmse < 0.05 {
                        finalT = res.transform
                    }
                }

                refinedMap[kf.index] = [
                    finalT.columns.0.x, finalT.columns.0.y, finalT.columns.0.z, finalT.columns.0.w,
                    finalT.columns.1.x, finalT.columns.1.y, finalT.columns.1.z, finalT.columns.1.w,
                    finalT.columns.2.x, finalT.columns.2.y, finalT.columns.2.z, finalT.columns.2.w,
                    finalT.columns.3.x, finalT.columns.3.y, finalT.columns.3.z, finalT.columns.3.w
                ]

                for p in localPts.prefix(300) {
                    let w = finalT * SIMD4<Float>(p, 1.0)
                    modelPoints.append(SIMD3<Float>(w.x, w.y, w.z))
                }
                if modelPoints.count > 6000 {
                    modelPoints = subsample(modelPoints, maxCount: 4000)
                }
            }

            let out = RefinedScanPoses(scanID: scanID, updatedAt: Date(), poses: refinedMap)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(out) {
                try? data.write(to: store.refinedPosesURL(projectID: projectID, scanID: scanID), options: .atomic)
            }

            DiagnosticsLogger.shared.log(.info, category: "Refinement", "Refined \(refinedMap.count) keyframe poses for scan \(scanID.uuidString.prefix(8))")
            DispatchQueue.main.async {
                completion(refinedMap.count)
            }
        }
    }

    // MARK: - Private Math

    private static func sampleLocalPoints(
        depthData: Data,
        kf: KeyframeRecord,
        nearClip: Float,
        farClip: Float
    ) -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        let fx = kf.intrinsics[0]
        let fy = kf.intrinsics[4]
        let cx = kf.intrinsics[6]
        let cy = kf.intrinsics[7]
        let scaleX = Float(kf.width) / Float(kf.depthWidth)
        let scaleY = Float(kf.height) / Float(kf.depthHeight)

        depthData.withUnsafeBytes { raw in
            let depths = raw.bindMemory(to: Float32.self)
            for dy in Swift.stride(from: 4, to: kf.depthHeight - 4, by: 8) {
                for dx in Swift.stride(from: 4, to: kf.depthWidth - 4, by: 8) {
                    let idx = dy * kf.depthWidth + dx
                    guard idx < depths.count else { continue }
                    let d = depths[idx]
                    if d.isNaN || d <= 0 || d < nearClip || d > farClip { continue }
                    let rgbX = (Float(dx) + 0.5) * scaleX
                    let rgbY = (Float(dy) + 0.5) * scaleY
                    pts.append(SIMD3<Float>((rgbX - cx) * d / fx, -(rgbY - cy) * d / fy, -d))
                }
            }
        }
        return pts
    }

    private static func nearestNeighbor(
        to p: SIMD3<Float>,
        in grid: [Int64: [SIMD3<Float>]],
        cellSize: Float,
        maxDistSq: Float
    ) -> (point: SIMD3<Float>, distSq: Float)? {
        var bestDistSq = maxDistSq
        var bestPt: SIMD3<Float>?

        let ix = Int(floor(p.x / cellSize))
        let iy = Int(floor(p.y / cellSize))
        let iz = Int(floor(p.z / cellSize))

        for dz in -1...1 {
            for dy in -1...1 {
                for dx in -1...1 {
                    let cx = Int64(ix + dx) & 0x1FFFFF
                    let cy = Int64(iy + dy) & 0x1FFFFF
                    let cz = Int64(iz + dz) & 0x1FFFFF
                    let key = (cx << 42) | (cy << 21) | cz
                    guard let bucket = grid[key] else { continue }
                    for cand in bucket {
                        let d2 = simd_distance_squared(p, cand)
                        if d2 < bestDistSq {
                            bestDistSq = d2
                            bestPt = cand
                        }
                    }
                }
            }
        }

        if let bestPt {
            return (bestPt, bestDistSq)
        }
        return nil
    }

    private static func kabschRigidTransform(from src: [SIMD3<Float>], to tgt: [SIMD3<Float>]) -> simd_float4x4 {
        let n = Float(src.count)
        var meanS = SIMD3<Float>.zero
        var meanT = SIMD3<Float>.zero
        for i in 0..<src.count {
            meanS += src[i]
            meanT += tgt[i]
        }
        meanS /= n
        meanT /= n

        // 3x3 covariance H = sum (s_i - meanS) * (t_i - meanT)^T (column-major for LAPACK)
        var h = [Double](repeating: 0, count: 9)
        for i in 0..<src.count {
            let s = SIMD3<Double>(Double(src[i].x - meanS.x), Double(src[i].y - meanS.y), Double(src[i].z - meanS.z))
            let t = SIMD3<Double>(Double(tgt[i].x - meanT.x), Double(tgt[i].y - meanT.y), Double(tgt[i].z - meanT.z))
            // Column-major: H[col*3 + row] = s[row] * t[col]
            h[0] += s.x * t.x; h[1] += s.y * t.x; h[2] += s.z * t.x
            h[3] += s.x * t.y; h[4] += s.y * t.y; h[5] += s.z * t.y
            h[6] += s.x * t.z; h[7] += s.y * t.z; h[8] += s.z * t.z
        }

        var jobu: Int8 = 65 // 'A'
        var jobvt: Int8 = 65 // 'A'
        var m: __CLPK_integer = 3
        var nCols: __CLPK_integer = 3
        var lda: __CLPK_integer = 3
        var sVals = [Double](repeating: 0, count: 3)
        var u = [Double](repeating: 0, count: 9)
        var ldu: __CLPK_integer = 3
        var vt = [Double](repeating: 0, count: 9)
        var ldvt: __CLPK_integer = 3
        var lwork: __CLPK_integer = 64
        var work = [Double](repeating: 0, count: 64)
        var info: __CLPK_integer = 0

        dgesvd_(&jobu, &jobvt, &m, &nCols, &h, &lda, &sVals, &u, &ldu, &vt, &ldvt, &work, &lwork, &info)
        guard info == 0 else { return matrix_identity_float4x4 }

        // R = V * U^T
        // vt is V^T (column-major: vt[col*3 + row] = V[col, row]), u is U (column-major: u[col*3 + row] = U[row, col])
        let uMat = simd_double3x3(
            SIMD3(u[0], u[1], u[2]),
            SIMD3(u[3], u[4], u[5]),
            SIMD3(u[6], u[7], u[8])
        )
        let vtMat = simd_double3x3(
            SIMD3(vt[0], vt[1], vt[2]),
            SIMD3(vt[3], vt[4], vt[5]),
            SIMD3(vt[6], vt[7], vt[8])
        )
        var vMat = vtMat.transpose
        var rMat = vMat * uMat.transpose

        if rMat.determinant < 0 {
            vMat.columns.2 *= -1
            rMat = vMat * uMat.transpose
        }

        let rFloat = simd_float3x3(
            SIMD3(Float(rMat.columns.0.x), Float(rMat.columns.0.y), Float(rMat.columns.0.z)),
            SIMD3(Float(rMat.columns.1.x), Float(rMat.columns.1.y), Float(rMat.columns.1.z)),
            SIMD3(Float(rMat.columns.2.x), Float(rMat.columns.2.y), Float(rMat.columns.2.z))
        )
        let t = meanT - rFloat * meanS

        var result = matrix_identity_float4x4
        result.columns.0 = SIMD4(rFloat.columns.0, 0)
        result.columns.1 = SIMD4(rFloat.columns.1, 0)
        result.columns.2 = SIMD4(rFloat.columns.2, 0)
        result.columns.3 = SIMD4(t, 1)
        return result
    }

    private static func subsample(_ pts: [SIMD3<Float>], maxCount: Int) -> [SIMD3<Float>] {
        guard pts.count > maxCount, maxCount > 0 else { return pts }
        let step = max(1, pts.count / maxCount)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(maxCount)
        for i in Swift.stride(from: 0, to: pts.count, by: step) {
            out.append(pts[i])
        }
        return out
    }
}
