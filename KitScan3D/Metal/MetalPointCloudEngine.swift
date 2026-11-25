import Foundation
import Metal
import MetalKit
import ARKit
import CoreVideo
import simd

struct PointVertex {
    var position: (Float, Float, Float)
    var color: (Float, Float, Float)

    init(position: SIMD3<Float>, color: SIMD3<Float>) {
        self.position = (position.x, position.y, position.z)
        self.color = (color.x, color.y, color.z)
    }

    var simdPosition: SIMD3<Float> {
        SIMD3<Float>(position.0, position.1, position.2)
    }
}

struct LineVertex {
    var position: (Float, Float, Float)
    var color: (Float, Float, Float, Float)

    init(position: SIMD3<Float>, color: SIMD4<Float>) {
        self.position = (position.x, position.y, position.z)
        self.color = (color.x, color.y, color.z, color.w)
    }
}

struct ViewfinderUniforms {
    var displayTransform: simd_float4x4
    var nearClip: Float
    var farClip: Float
    var showDepthPreview: UInt32
    var showCoverageOverlay: UInt32
}

struct UnprojectUniforms {
    var cameraTransform: simd_float4x4
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    var rgbWidth: UInt32
    var rgbHeight: UInt32
    var depthWidth: UInt32
    var depthHeight: UInt32
    var nearClip: Float
    var farClip: Float
    var minConfidence: UInt32
    var stride: UInt32
    var maxOutputPoints: UInt32
    var frameIndex: UInt32
    var maxEdgeJumpMeters: Float
}

struct Scene3DUniforms {
    var viewProjection: simd_float4x4
    var pointSize: Float
}

enum VoxelHash {
    /// Packs signed 21-bit voxel coordinates into a 64-bit integer key.
    static func key(for point: SIMD3<Float>, spacing: Float) -> Int64 {
        let s = max(0.001, spacing)
        let ix = Int64(floor(point.x / s)) & 0x1FFFFF
        let iy = Int64(floor(point.y / s)) & 0x1FFFFF
        let iz = Int64(floor(point.z / s)) & 0x1FFFFF
        return (ix << 42) | (iy << 21) | iz
    }

    /// Returns a world-consistent voxel size so overlapping frames always hash to the same 3D grid.
    static func voxelSpacing(for settings: CaptureSettings) -> Float {
        if settings.spacingMode == .adaptive {
            return max(0.005, min(0.025, settings.farClipMeters * 0.0018))
        }
        return min(0.05, max(0.002, settings.manualSpacingMeters))
    }
}

/// Manages Metal pipelines, live ARFrame textures, GPU depth unprojection, and voxel-hashed point cloud accumulation.
final class MetalPointCloudEngine: ObservableObject {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private(set) var viewfinderPipeline: MTLRenderPipelineState?
    private(set) var pointCloudPipeline: MTLRenderPipelineState?
    private(set) var linePipeline: MTLRenderPipelineState?
    private(set) var unprojectPipeline: MTLComputePipelineState?

    private var textureCache: CVMetalTextureCache?
    private var unprojectStagingBuffer: MTLBuffer?
    private var unprojectCountBuffer: MTLBuffer?
    private let maxStagingPoints = 40_000

    private let accumulatorQueue = DispatchQueue(label: "com.kitscan3d.voxelaccumulator", qos: .userInitiated)
    private var voxelMap: [Int64: PointVertex] = [:]
    private var voxelCounts: [Int64: UInt16] = [:]
    private var coverageVoxels: Set<Int64> = []
    private let coverageVoxelSpacing: Float = 0.04
    private let covWidth = 128
    private let covHeight = 96
    private var unprojectFrameCounter: UInt32 = 0

    @Published private(set) var totalPointCount: Int = 0
    @Published private(set) var preview2DPoints: [SIMD2<Float>] = []

    private let renderLock = NSLock()
    private var renderPointBuffer: MTLBuffer?
    private var renderPointCount: Int = 0
    private var coverageTexture: MTLTexture?

    // Latest ARFrame textures for live viewfinder
    private var latestYTex: MTLTexture?
    private var latestCbCrTex: MTLTexture?
    private var latestDepthTex: MTLTexture?
    private var latestDisplayTransform: simd_float4x4 = matrix_identity_float4x4

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            DiagnosticsLogger.shared.log(.error, category: "Metal", "Failed to create MTLDevice or MTLCommandQueue")
            return nil
        }
        self.device = dev
        self.commandQueue = queue
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &textureCache)

        self.unprojectStagingBuffer = dev.makeBuffer(
            length: MemoryLayout<PointVertex>.stride * maxStagingPoints,
            options: .storageModeShared
        )
        self.unprojectCountBuffer = dev.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        )

        setupPipelines()
        setupEmptyCoverageTexture()
    }

    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else {
            DiagnosticsLogger.shared.log(.error, category: "Metal", "Failed to load default.metallib")
            return
        }

        // Viewfinder render pipeline
        let vfDesc = MTLRenderPipelineDescriptor()
        vfDesc.vertexFunction = library.makeFunction(name: "viewfinderVertex")
        vfDesc.fragmentFunction = library.makeFunction(name: "viewfinderFragment")
        vfDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        viewfinderPipeline = try? device.makeRenderPipelineState(descriptor: vfDesc)

        // 3D Point cloud render pipeline
        let pcDesc = MTLRenderPipelineDescriptor()
        pcDesc.vertexFunction = library.makeFunction(name: "pointCloudVertex")
        pcDesc.fragmentFunction = library.makeFunction(name: "pointCloudFragment")
        pcDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pcDesc.depthAttachmentPixelFormat = .depth32Float
        pointCloudPipeline = try? device.makeRenderPipelineState(descriptor: pcDesc)

        // 3D Line render pipeline
        let lineDesc = MTLRenderPipelineDescriptor()
        lineDesc.vertexFunction = library.makeFunction(name: "lineVertex")
        lineDesc.fragmentFunction = library.makeFunction(name: "lineFragment")
        lineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        lineDesc.depthAttachmentPixelFormat = .depth32Float
        linePipeline = try? device.makeRenderPipelineState(descriptor: lineDesc)

        // Compute pipeline
        if let fn = library.makeFunction(name: "unprojectDepthKernel") {
            unprojectPipeline = try? device.makeComputePipelineState(function: fn)
        }
    }

    private func setupEmptyCoverageTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: covWidth, height: covHeight, mipmapped: false)
        desc.usage = [.shaderRead]
        coverageTexture = device.makeTexture(descriptor: desc)
        var zeros = [UInt8](repeating: 0, count: covWidth * covHeight)
        coverageTexture?.replace(
            region: MTLRegionMake2D(0, 0, covWidth, covHeight),
            mipmapLevel: 0,
            withBytes: &zeros,
            bytesPerRow: covWidth
        )
    }

    func updateCoverageMask(for frame: ARFrame, settings: CaptureSettings) {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let covTex = coverageTexture else { return }

        let depthMap = depthData.depthMap
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let camRes = frame.camera.imageResolution

        accumulatorQueue.async { [weak self] in
            guard let self else { return }
            if self.coverageVoxels.isEmpty { return }

            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }

            let dW = CVPixelBufferGetWidth(depthMap)
            let dH = CVPixelBufferGetHeight(depthMap)
            let bpr = CVPixelBufferGetBytesPerRow(depthMap)
            let fx = intrinsics.columns.0.x * Float(dW) / Float(camRes.width)
            let fy = intrinsics.columns.1.y * Float(dH) / Float(camRes.height)
            let cx = intrinsics.columns.2.x * Float(dW) / Float(camRes.width)
            let cy = intrinsics.columns.2.y * Float(dH) / Float(camRes.height)

            var mask = [UInt8](repeating: 0, count: self.covWidth * self.covHeight)

            for cyIdx in 0..<self.covHeight {
                let dy = min(dH - 1, (cyIdx * dH) / self.covHeight)
                let rowPtr = base.advanced(by: dy * bpr).assumingMemoryBound(to: Float32.self)
                for cxIdx in 0..<self.covWidth {
                    let dx = min(dW - 1, (cxIdx * dW) / self.covWidth)
                    let d = rowPtr[dx]
                    if d.isNaN || d <= 0 || d < settings.nearClipMeters || d > settings.farClipMeters {
                        continue
                    }
                    let xCam = (Float(dx) + 0.5 - cx) * d / fx
                    let yCam = -(Float(dy) + 0.5 - cy) * d / fy
                    let zCam = -d
                    let world = transform * SIMD4<Float>(xCam, yCam, zCam, 1.0)
                    let pos = SIMD3<Float>(world.x, world.y, world.z)

                    let covKey = VoxelHash.key(for: pos, spacing: self.coverageVoxelSpacing)
                    if self.coverageVoxels.contains(covKey) {
                        mask[cyIdx * self.covWidth + cxIdx] = 255
                    }
                }
            }

            covTex.replace(
                region: MTLRegionMake2D(0, 0, self.covWidth, self.covHeight),
                mipmapLevel: 0,
                withBytes: &mask,
                bytesPerRow: self.covWidth
            )
        }
    }

    func resetPointCloud() {
        accumulatorQueue.async { [weak self] in
            guard let self else { return }
            self.voxelMap.removeAll(keepingCapacity: false)
            self.voxelCounts.removeAll(keepingCapacity: false)
            self.coverageVoxels.removeAll(keepingCapacity: false)
            var zeros = [UInt8](repeating: 0, count: self.covWidth * self.covHeight)
            self.coverageTexture?.replace(
                region: MTLRegionMake2D(0, 0, self.covWidth, self.covHeight),
                mipmapLevel: 0,
                withBytes: &zeros,
                bytesPerRow: self.covWidth
            )
            self.renderLock.lock()
            self.renderPointBuffer = nil
            self.renderPointCount = 0
            self.renderLock.unlock()
            DispatchQueue.main.async {
                self.totalPointCount = 0
                self.preview2DPoints = []
            }
        }
    }

    func updateLiveFrame(_ frame: ARFrame, viewportSize: CGSize) {
        guard let cache = textureCache else { return }

        let yTex = makeTexture(from: frame.capturedImage, pixelFormat: .r8Unorm, planeIndex: 0, cache: cache)
        let cbcrTex = makeTexture(from: frame.capturedImage, pixelFormat: .rg8Unorm, planeIndex: 1, cache: cache)
        let depthTex: MTLTexture? = frame.sceneDepth.flatMap {
            makeTexture(from: $0.depthMap, pixelFormat: .r32Float, planeIndex: 0, cache: cache)
        }

        let affine = frame.displayTransform(for: .portrait, viewportSize: viewportSize).inverted()
        let mat = simd_float4x4(
            SIMD4<Float>(Float(affine.a), Float(affine.b), 0, 0),
            SIMD4<Float>(Float(affine.c), Float(affine.d), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(Float(affine.tx), Float(affine.ty), 0, 1)
        )

        renderLock.lock()
        self.latestYTex = yTex
        self.latestCbCrTex = cbcrTex
        self.latestDepthTex = depthTex
        self.latestDisplayTransform = mat
        renderLock.unlock()
    }

    /// Runs GPU unprojection on a captured keyframe and merges points into the voxel spatial hash.
    func processCapturedKeyframe(_ frame: ARFrame, settings: CaptureSettings) {
        guard let cache = textureCache,
              let pipeline = unprojectPipeline,
              let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let stagingBuf = unprojectStagingBuffer,
              let countBuf = unprojectCountBuffer,
              let yTex = makeTexture(from: frame.capturedImage, pixelFormat: .r8Unorm, planeIndex: 0, cache: cache),
              let cbcrTex = makeTexture(from: frame.capturedImage, pixelFormat: .rg8Unorm, planeIndex: 1, cache: cache),
              let depthTex = makeTexture(from: depthData.depthMap, pixelFormat: .r32Float, planeIndex: 0, cache: cache),
              let confMap = depthData.confidenceMap,
              let confTex = makeTexture(from: confMap, pixelFormat: .r8Uint, planeIndex: 0, cache: cache),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            return
        }

        let countPtr = countBuf.contents().bindMemory(to: UInt32.self, capacity: 1)
        countPtr.pointee = 0

        let rgbW = CVPixelBufferGetWidth(frame.capturedImage)
        let rgbH = CVPixelBufferGetHeight(frame.capturedImage)
        let depW = CVPixelBufferGetWidth(depthData.depthMap)
        let depH = CVPixelBufferGetHeight(depthData.depthMap)

        let intrinsics = CameraCalibration.scaledIntrinsics(
            frame.camera.intrinsics,
            from: frame.camera.imageResolution,
            to: rgbW,
            targetHeight: rgbH
        )

        let stride: UInt32 = settings.manualSpacingMeters <= 0.005 ? 1 : 2
        unprojectFrameCounter &+= 1
        var uniforms = UnprojectUniforms(
            cameraTransform: frame.camera.transform,
            fx: intrinsics.columns.0.x,
            fy: intrinsics.columns.1.y,
            cx: intrinsics.columns.2.x,
            cy: intrinsics.columns.2.y,
            rgbWidth: UInt32(rgbW),
            rgbHeight: UInt32(rgbH),
            depthWidth: UInt32(depW),
            depthHeight: UInt32(depH),
            nearClip: settings.nearClipMeters,
            farClip: settings.farClipMeters,
            minConfidence: UInt32(settings.minDepthConfidence),
            stride: stride,
            maxOutputPoints: UInt32(maxStagingPoints),
            frameIndex: unprojectFrameCounter,
            maxEdgeJumpMeters: 0.04
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(yTex, index: 0)
        encoder.setTexture(cbcrTex, index: 1)
        encoder.setTexture(depthTex, index: 2)
        encoder.setTexture(confTex, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<UnprojectUniforms>.stride, index: 0)
        encoder.setBuffer(stagingBuf, offset: 0, index: 1)
        encoder.setBuffer(countBuf, offset: 0, index: 2)

        let gridW = (depW + Int(stride) - 1) / Int(stride)
        let gridH = (depH + Int(stride) - 1) / Int(stride)
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width: (gridW + 15) / 16,
            height: (gridH + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()

        cmdBuf.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let rawCount = min(Int(countPtr.pointee), self.maxStagingPoints)
            guard rawCount > 0 else { return }
            let ptr = stagingBuf.contents().bindMemory(to: PointVertex.self, capacity: rawCount)
            let batch = Array(UnsafeBufferPointer(start: ptr, count: rawCount))

            self.accumulatorQueue.async {
                let budget = settings.maxPointBudget
                let spacing = VoxelHash.voxelSpacing(for: settings)
                for pt in batch {
                    let pos = pt.simdPosition
                    self.accumulatePoint(pt, spacing: spacing, budget: budget)
                    self.coverageVoxels.insert(VoxelHash.key(for: pos, spacing: self.coverageVoxelSpacing))
                }

                let allPoints = Array(self.voxelMap.values)
                let newBuf = self.device.makeBuffer(
                    bytes: allPoints,
                    length: MemoryLayout<PointVertex>.stride * allPoints.count,
                    options: .storageModeShared
                )

                // Subsample up to 4,000 points for lightweight 2D top-down map
                let step2D = max(1, allPoints.count / 4000)
                var pts2D: [SIMD2<Float>] = []
                pts2D.reserveCapacity(min(allPoints.count, 4000))
                for i in Swift.stride(from: 0, to: allPoints.count, by: step2D) {
                    let p = allPoints[i].position
                    pts2D.append(SIMD2<Float>(p.0, p.2))
                }

                self.renderLock.lock()
                self.renderPointBuffer = newBuf
                self.renderPointCount = allPoints.count
                self.renderLock.unlock()

                DispatchQueue.main.async {
                    self.totalPointCount = allPoints.count
                    self.preview2DPoints = pts2D
                }
            }
        }

        cmdBuf.commit()
    }

    func snapshotViewfinderTextures() -> (y: MTLTexture?, cbcr: MTLTexture?, depth: MTLTexture?, cov: MTLTexture?, transform: simd_float4x4) {
        renderLock.lock()
        defer { renderLock.unlock() }
        return (latestYTex, latestCbCrTex, latestDepthTex, coverageTexture, latestDisplayTransform)
    }

    func snapshot3DPointBuffer() -> (buffer: MTLBuffer?, count: Int) {
        renderLock.lock()
        defer { renderLock.unlock() }
        return (renderPointBuffer, renderPointCount)
    }

    func exportCurrentPointsSnapshot(completion: @escaping ([PointVertex]) -> Void) {
        accumulatorQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let pts = Array(self.voxelMap.values)
            DispatchQueue.main.async {
                completion(pts)
            }
        }
    }

    /// Merges a point into the voxel hash using a running mean of position and color.
    private func accumulatePoint(_ pt: PointVertex, spacing: Float, budget: Int) {
        let pos = pt.simdPosition
        let key = VoxelHash.key(for: pos, spacing: spacing)
        if let existing = voxelMap[key] {
            let n = min(UInt16(32), (voxelCounts[key] ?? 1) &+ 1)
            let w = 1.0 / Float(n)
            let ePos = existing.simdPosition
            let eCol = SIMD3<Float>(existing.color.0, existing.color.1, existing.color.2)
            let nCol = SIMD3<Float>(pt.color.0, pt.color.1, pt.color.2)
            let meanPos = ePos + (pos - ePos) * w
            let meanCol = eCol + (nCol - eCol) * w
            voxelMap[key] = PointVertex(position: meanPos, color: meanCol)
            voxelCounts[key] = n
        } else if voxelMap.count < budget {
            voxelMap[key] = pt
            voxelCounts[key] = 1
        }
    }

    private static func pcgHash(_ v: UInt32) -> UInt32 {
        let state = v &* 747796405 &+ 2891336453
        let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277803737
        return (word >> 22) ^ word
    }

    /// Rebuilds the 3D point cloud and trajectory from saved keyframes on disk for a project.
    func loadProjectFromDisk(projectID: UUID, settings: CaptureSettings, completion: @escaping ([simd_float4x4]) -> Void) {
        accumulatorQueue.async { [weak self] in
            guard let self else { return }
            self.voxelMap.removeAll(keepingCapacity: false)
            self.voxelCounts.removeAll(keepingCapacity: false)
            var poses: [simd_float4x4] = []

            let store = ScanProjectStore.shared
            let scans = store.loadScans(for: projectID).sorted { $0.createdAt < $1.createdAt }
            let decoder = JSONDecoder()
            let spacing = VoxelHash.voxelSpacing(for: settings)
            var frameIndex: UInt32 = 0

            for scan in scans {
                let scanDir = store.scanDirectory(projectID: projectID, scanID: scan.id)
                let jsonlURL = scanDir.appendingPathComponent("keyframes.jsonl")
                guard let content = try? String(contentsOf: jsonlURL, encoding: .utf8) else { continue }

                for line in content.split(separator: "\n") {
                    guard let lineData = line.data(using: .utf8),
                          let kf = try? decoder.decode(KeyframeRecord.self, from: lineData),
                          kf.intrinsics.count == 9,
                          kf.transform.count == 16 else { continue }

                    let transform = simd_float4x4(
                        SIMD4(kf.transform[0], kf.transform[1], kf.transform[2], kf.transform[3]),
                        SIMD4(kf.transform[4], kf.transform[5], kf.transform[6], kf.transform[7]),
                        SIMD4(kf.transform[8], kf.transform[9], kf.transform[10], kf.transform[11]),
                        SIMD4(kf.transform[12], kf.transform[13], kf.transform[14], kf.transform[15])
                    )
                    poses.append(transform)

                    let depthURL = scanDir.appendingPathComponent("depth/\(kf.depthFilename)")
                    let confURL = scanDir.appendingPathComponent("confidence/\(kf.confidenceFilename)")
                    let rgbURL = scanDir.appendingPathComponent("rgb/\(kf.rgbFilename)")

                    guard let depthData = try? Data(contentsOf: depthURL),
                          let uiImage = UIImage(contentsOfFile: rgbURL.path),
                          let cgImage = uiImage.cgImage,
                          let rgbBytes = cgImage.dataProvider?.data as Data? else { continue }

                    let confData = try? Data(contentsOf: confURL)
                    let fx = kf.intrinsics[0]
                    let fy = kf.intrinsics[4]
                    let cx = kf.intrinsics[6]
                    let cy = kf.intrinsics[7]

                    let bpp = cgImage.bitsPerPixel / 8
                    let bpr = cgImage.bytesPerRow
                    let strideStep = settings.manualSpacingMeters <= 0.005 ? 1 : 2
                    let scaleX = Float(kf.width) / Float(kf.depthWidth)
                    let scaleY = Float(kf.height) / Float(kf.depthHeight)
                    frameIndex &+= 1

                    depthData.withUnsafeBytes { rawDepth in
                        let depths = rawDepth.bindMemory(to: Float32.self)
                        let confs = confData?.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }

                        for gy in 0..<((kf.depthHeight + strideStep - 1) / strideStep) {
                            for gx in 0..<((kf.depthWidth + strideStep - 1) / strideStep) {
                                let jx = strideStep > 1 ? Int(Self.pcgHash(UInt32(gx) &* 73856093 ^ UInt32(gy) &* 19349663 ^ frameIndex &* 83492791) % UInt32(strideStep)) : 0
                                let jy = strideStep > 1 ? Int(Self.pcgHash(UInt32(gx) &* 2971215073 ^ UInt32(gy) &* 486187739 ^ frameIndex &* 15485863) % UInt32(strideStep)) : 0
                                let dx = gx * strideStep + jx
                                let dy = gy * strideStep + jy
                                guard dx < kf.depthWidth, dy < kf.depthHeight else { continue }

                                let dIdx = dy * kf.depthWidth + dx
                                guard dIdx < depths.count else { continue }
                                let rawD = depths[dIdx]
                                if rawD.isNaN || rawD <= 0 || rawD < settings.nearClipMeters || rawD > settings.farClipMeters { continue }
                                if let confs, dIdx < confs.count, Int(confs[dIdx]) < settings.minDepthConfidence { continue }

                                // 3x3 edge-jump & confidence filter
                                let edgeThreshold = min(Float(0.04), max(Float(0.015), rawD * 0.035))
                                var sumW: Float = 1.0
                                var sumD: Float = rawD
                                var jumpCount = 0
                                for oy in -1...1 {
                                    for ox in -1...1 {
                                        if ox == 0 && oy == 0 { continue }
                                        let nx = dx + ox
                                        let ny = dy + oy
                                        if nx < 0 || ny < 0 || nx >= kf.depthWidth || ny >= kf.depthHeight {
                                            jumpCount += 1
                                            continue
                                        }
                                        let nIdx = ny * kf.depthWidth + nx
                                        if let confs, nIdx < confs.count, Int(confs[nIdx]) < settings.minDepthConfidence {
                                            jumpCount += 1
                                            continue
                                        }
                                        let nd = depths[nIdx]
                                        if nd.isNaN || nd <= 0 {
                                            jumpCount += 1
                                            continue
                                        }
                                        let diff = abs(nd - rawD)
                                        if diff > edgeThreshold {
                                            jumpCount += 1
                                        } else {
                                            let sigma2 = max(Float(0.0001), (edgeThreshold * 0.5) * (edgeThreshold * 0.5))
                                            let rw = exp(-(diff * diff) / sigma2)
                                            sumD += nd * rw
                                            sumW += rw
                                        }
                                    }
                                }
                                if jumpCount >= 2 { continue }
                                let d = sumD / sumW

                                // Grazing angle rejection
                                if dx > 0, dx + 1 < kf.depthWidth, dy > 0, dy + 1 < kf.depthHeight {
                                    let dL = depths[dy * kf.depthWidth + (dx - 1)]
                                    let dR = depths[dy * kf.depthWidth + (dx + 1)]
                                    let dU = depths[(dy - 1) * kf.depthWidth + dx]
                                    let dD = depths[(dy + 1) * kf.depthWidth + dx]
                                    let slopeX = (0.5 * (dR - dL)) / max(1e-4, d * (scaleX / fx))
                                    let slopeY = (0.5 * (dD - dU)) / max(1e-4, d * (scaleY / fy))
                                    if slopeX * slopeX + slopeY * slopeY > 9.0 { continue }
                                }

                                let h1 = Self.pcgHash(UInt32(dx) &* 73856093 ^ UInt32(dy) &* 19349663 ^ frameIndex &* 83492791)
                                let h2 = Self.pcgHash(UInt32(dx) &* 2971215073 ^ UInt32(dy) &* 486187739 ^ frameIndex &* 15485863)
                                let subX = (Float(h1 & 0xFFFF) / 65535.0 - 0.5) * 0.9
                                let subY = (Float(h2 & 0xFFFF) / 65535.0 - 0.5) * 0.9

                                let rgbX = (Float(dx) + 0.5 + subX) * scaleX
                                let rgbY = (Float(dy) + 0.5 + subY) * scaleY
                                let ux = min(max(0, Int(rgbX)), cgImage.width - 1)
                                let uy = min(max(0, Int(rgbY)), cgImage.height - 1)
                                let pOffset = uy * bpr + ux * bpp

                                var color = SIMD3<Float>(0.8, 0.8, 0.8)
                                if pOffset + 2 < rgbBytes.count {
                                    color = SIMD3<Float>(
                                        Float(rgbBytes[pOffset]) / 255.0,
                                        Float(rgbBytes[pOffset + 1]) / 255.0,
                                        Float(rgbBytes[pOffset + 2]) / 255.0
                                    )
                                }

                                let xCam = (rgbX - cx) * d / fx
                                let yCam = -(rgbY - cy) * d / fy
                                let zCam = -d
                                let world = transform * SIMD4<Float>(xCam, yCam, zCam, 1.0)
                                let pos = SIMD3<Float>(world.x, world.y, world.z)

                                self.accumulatePoint(PointVertex(position: pos, color: color), spacing: spacing, budget: settings.maxPointBudget)
                            }
                        }
                    }
                }
            }

            let allPoints = Array(self.voxelMap.values)
            let newBuf = allPoints.isEmpty ? nil : self.device.makeBuffer(
                bytes: allPoints,
                length: MemoryLayout<PointVertex>.stride * allPoints.count,
                options: .storageModeShared
            )

            self.renderLock.lock()
            self.renderPointBuffer = newBuf
            self.renderPointCount = allPoints.count
            self.renderLock.unlock()

            DispatchQueue.main.async {
                self.totalPointCount = allPoints.count
                completion(poses)
            }
        }
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        planeIndex: Int,
        cache: CVMetalTextureCache
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }
}
