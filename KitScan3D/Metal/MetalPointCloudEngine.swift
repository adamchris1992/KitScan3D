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
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 64, height: 48, mipmapped: false)
        desc.usage = [.shaderRead]
        coverageTexture = device.makeTexture(descriptor: desc)
    }

    func resetPointCloud() {
        accumulatorQueue.async { [weak self] in
            guard let self else { return }
            self.voxelMap.removeAll(keepingCapacity: false)
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
              let depthData = frame.sceneDepth,
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
            maxOutputPoints: UInt32(maxStagingPoints)
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

        let camPos = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )

        cmdBuf.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let rawCount = min(Int(countPtr.pointee), self.maxStagingPoints)
            guard rawCount > 0 else { return }
            let ptr = stagingBuf.contents().bindMemory(to: PointVertex.self, capacity: rawCount)
            let batch = Array(UnsafeBufferPointer(start: ptr, count: rawCount))

            self.accumulatorQueue.async {
                let budget = settings.maxPointBudget
                for pt in batch {
                    if self.voxelMap.count >= budget {
                        break
                    }
                    let pos = pt.simdPosition
                    let spacing: Float
                    if settings.spacingMode == .adaptive {
                        let dist = simd_distance(pos, camPos)
                        spacing = max(0.002, min(0.05, dist * 0.004))
                    } else {
                        spacing = min(0.05, max(0.001, settings.manualSpacingMeters))
                    }
                    let key = VoxelHash.key(for: pos, spacing: spacing)
                    if self.voxelMap[key] == nil {
                        self.voxelMap[key] = pt
                    }
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

    /// Rebuilds the 3D point cloud and trajectory from saved keyframes on disk for a project.
    func loadProjectFromDisk(projectID: UUID, settings: CaptureSettings, completion: @escaping ([simd_float4x4]) -> Void) {
        accumulatorQueue.async { [weak self] in
            guard let self else { return }
            self.voxelMap.removeAll(keepingCapacity: false)
            var poses: [simd_float4x4] = []

            let store = ScanProjectStore.shared
            let scans = store.loadScans(for: projectID).sorted { $0.createdAt < $1.createdAt }
            let decoder = JSONDecoder()

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
                    let camPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

                    let bpp = cgImage.bitsPerPixel / 8
                    let bpr = cgImage.bytesPerRow
                    let strideStep = 2

                    depthData.withUnsafeBytes { rawDepth in
                        let depths = rawDepth.bindMemory(to: Float32.self)
                        let confs = confData?.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }

                        for dy in Swift.stride(from: 0, to: kf.depthHeight, by: strideStep) {
                            for dx in Swift.stride(from: 0, to: kf.depthWidth, by: strideStep) {
                                if self.voxelMap.count >= settings.maxPointBudget { break }
                                let dIdx = dy * kf.depthWidth + dx
                                guard dIdx < depths.count else { continue }
                                let d = depths[dIdx]
                                if d.isNaN || d <= 0 || d < settings.nearClipMeters || d > settings.farClipMeters { continue }
                                if let confs, dIdx < confs.count, Int(confs[dIdx]) < settings.minDepthConfidence { continue }

                                let rgbX = (Float(dx) + 0.5) * Float(kf.width) / Float(kf.depthWidth)
                                let rgbY = (Float(dy) + 0.5) * Float(kf.height) / Float(kf.depthHeight)
                                let ux = min(Int(rgbX), cgImage.width - 1)
                                let uy = min(Int(rgbY), cgImage.height - 1)
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

                                let spacing: Float = settings.spacingMode == .adaptive
                                    ? max(0.002, min(0.05, simd_distance(pos, camPos) * 0.004))
                                    : min(0.05, max(0.001, settings.manualSpacingMeters))

                                let key = VoxelHash.key(for: pos, spacing: spacing)
                                if self.voxelMap[key] == nil {
                                    self.voxelMap[key] = PointVertex(position: pos, color: color)
                                }
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
