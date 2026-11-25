import SwiftUI
import MetalKit
import simd

struct LiveCameraMetalView: UIViewRepresentable {
    @ObservedObject var engine: MetalPointCloudEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeUIView(context: Context) -> MTKView {
        let mtk = MTKView()
        mtk.device = engine.device
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.framebufferOnly = true
        mtk.preferredFramesPerSecond = 60
        mtk.delegate = context.coordinator
        return mtk
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let engine: MetalPointCloudEngine

        init(engine: MetalPointCloudEngine) {
            self.engine = engine
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline = engine.viewfinderPipeline,
                  let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let cmdBuf = engine.commandQueue.makeCommandBuffer(),
                  let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
                return
            }

            let snap = engine.snapshotViewfinderTextures()
            guard let y = snap.y, let cbcr = snap.cbcr else {
                encoder.endEncoding()
                cmdBuf.present(drawable)
                cmdBuf.commit()
                return
            }

            var uniforms = ViewfinderUniforms(displayTransform: snap.transform)

            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewfinderUniforms>.stride, index: 0)
            encoder.setFragmentTexture(y, index: 0)
            encoder.setFragmentTexture(cbcr, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            cmdBuf.present(drawable)
            cmdBuf.commit()
        }
    }
}

struct PointCloud3DMetalView: UIViewRepresentable {
    @ObservedObject var engine: MetalPointCloudEngine
    let trajectoryPoses: [simd_float4x4]
    let currentPose: simd_float4x4
    var showLiveFrustum: Bool = true
    var showTrajectory: Bool = true
    var pointSize: Float = 3.4

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeUIView(context: Context) -> MTKView {
        let mtk = MTKView()
        mtk.device = engine.device
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.depthStencilPixelFormat = .depth32Float
        mtk.clearColor = MTLClearColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        mtk.preferredFramesPerSecond = 60
        mtk.delegate = context.coordinator

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        mtk.addGestureRecognizer(pan)
        mtk.addGestureRecognizer(pinch)

        return mtk
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.trajectoryPoses = trajectoryPoses
        context.coordinator.currentPose = currentPose
        context.coordinator.showLiveFrustum = showLiveFrustum
        context.coordinator.showTrajectory = showTrajectory
        context.coordinator.pointSize = pointSize
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let engine: MetalPointCloudEngine
        var trajectoryPoses: [simd_float4x4] = []
        var currentPose: simd_float4x4 = matrix_identity_float4x4
        var showLiveFrustum: Bool = true
        var showTrajectory: Bool = true
        var pointSize: Float = 3.4

        private var depthStencilState: MTLDepthStencilState?
        private var yaw: Float = 0.6
        private var pitch: Float = 0.5
        private var distance: Float = 4.5
        private var target = SIMD3<Float>(0, 0, 0)

        init(engine: MetalPointCloudEngine) {
            self.engine = engine
            super.init()
            let dsDesc = MTLDepthStencilDescriptor()
            dsDesc.depthCompareFunction = .less
            dsDesc.isDepthWriteEnabled = true
            self.depthStencilState = engine.device.makeDepthStencilState(descriptor: dsDesc)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let t = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            if gesture.numberOfTouches >= 2 {
                let scale = distance * 0.002
                target.x -= Float(t.x) * scale
                target.y += Float(t.y) * scale
            } else {
                yaw -= Float(t.x) * 0.008
                pitch = min(1.45, max(-1.45, pitch + Float(t.y) * 0.008))
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            distance = min(30.0, max(0.4, distance / Float(gesture.scale)))
            gesture.scale = 1.0
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let cmdBuf = engine.commandQueue.makeCommandBuffer(),
                  let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
                return
            }

            if let ds = depthStencilState {
                encoder.setDepthStencilState(ds)
            }

            let aspect = Float(max(1.0, view.drawableSize.width) / max(1.0, view.drawableSize.height))
            let viewProj = makeViewProjection(aspect: aspect)
            var uniforms = Scene3DUniforms(viewProjection: viewProj, pointSize: pointSize)

            let snap = engine.snapshot3DPointBuffer()
            if let pcPipeline = engine.pointCloudPipeline,
               let buf = snap.buffer,
               snap.count > 0 {
                encoder.setRenderPipelineState(pcPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Scene3DUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: snap.count)
            }

            // Draw trajectory + active camera frustum
            let lineVerts = showTrajectory ? buildTrajectoryAndFrustumVertices() : []
            if let lPipeline = engine.linePipeline, !lineVerts.isEmpty {
                encoder.setRenderPipelineState(lPipeline)
                encoder.setVertexBytes(lineVerts, length: MemoryLayout<LineVertex>.stride * lineVerts.count, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Scene3DUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineVerts.count)
            }

            encoder.endEncoding()
            cmdBuf.present(drawable)
            cmdBuf.commit()
        }

        private func buildTrajectoryAndFrustumVertices() -> [LineVertex] {
            var verts: [LineVertex] = []
            let trajColor = SIMD4<Float>(0.2, 0.85, 1.0, 1.0)
            if trajectoryPoses.count > 1 {
                for i in 0..<(trajectoryPoses.count - 1) {
                    let p0 = SIMD3<Float>(trajectoryPoses[i].columns.3.x, trajectoryPoses[i].columns.3.y, trajectoryPoses[i].columns.3.z)
                    let p1 = SIMD3<Float>(trajectoryPoses[i + 1].columns.3.x, trajectoryPoses[i + 1].columns.3.y, trajectoryPoses[i + 1].columns.3.z)
                    verts.append(LineVertex(position: p0, color: trajColor))
                    verts.append(LineVertex(position: p1, color: trajColor))
                }
            }

            if showLiveFrustum {
                // Frustum at currentPose
                let frustumColor = SIMD4<Float>(1.0, 0.8, 0.15, 1.0)
                let origin = SIMD3<Float>(currentPose.columns.3.x, currentPose.columns.3.y, currentPose.columns.3.z)
                let cornersLocal: [SIMD3<Float>] = [
                    SIMD3(-0.12,  0.09, -0.22),
                    SIMD3( 0.12,  0.09, -0.22),
                    SIMD3( 0.12, -0.09, -0.22),
                    SIMD3(-0.12, -0.09, -0.22)
                ]
                let cornersWorld = cornersLocal.map { local -> SIMD3<Float> in
                    let w = currentPose * SIMD4<Float>(local, 1.0)
                    return SIMD3<Float>(w.x, w.y, w.z)
                }
                for i in 0..<4 {
                    verts.append(LineVertex(position: origin, color: frustumColor))
                    verts.append(LineVertex(position: cornersWorld[i], color: frustumColor))
                    verts.append(LineVertex(position: cornersWorld[i], color: frustumColor))
                    verts.append(LineVertex(position: cornersWorld[(i + 1) % 4], color: frustumColor))
                }
            }
            return verts
        }

        private func makeViewProjection(aspect: Float) -> simd_float4x4 {
            let eye = target + SIMD3<Float>(
                distance * cos(pitch) * sin(yaw),
                distance * sin(pitch),
                distance * cos(pitch) * cos(yaw)
            )
            let view = lookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
            let proj = perspective(fovYRadians: .pi / 3.0, aspect: aspect, nearZ: 0.05, farZ: 100.0)
            return proj * view
        }

        private func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
            let f = simd_normalize(center - eye)
            let s = simd_normalize(simd_cross(f, up))
            let u = simd_cross(s, f)
            return simd_float4x4(
                SIMD4<Float>(s.x, u.x, -f.x, 0),
                SIMD4<Float>(s.y, u.y, -f.y, 0),
                SIMD4<Float>(s.z, u.z, -f.z, 0),
                SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
            )
        }

        private func perspective(fovYRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
            let yScale = 1.0 / tan(fovYRadians * 0.5)
            let xScale = yScale / aspect
            let zRange = farZ - nearZ
            let zScale = -(farZ + nearZ) / zRange
            let wzScale = -2.0 * farZ * nearZ / zRange
            return simd_float4x4(
                SIMD4<Float>(xScale, 0, 0, 0),
                SIMD4<Float>(0, yScale, 0, 0),
                SIMD4<Float>(0, 0, zScale, -1),
                SIMD4<Float>(0, 0, wzScale, 0)
            )
        }
    }
}
