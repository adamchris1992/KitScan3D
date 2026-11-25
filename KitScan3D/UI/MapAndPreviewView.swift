import SwiftUI
import simd

/// Live 2D top-down (X-Z) map showing accumulated points, camera trajectory, and active viewing frustum.
struct TopDown2DMapView: View {
    let points2D: [SIMD2<Float>]
    let trajectoryPoses: [simd_float4x4]
    let currentPose: simd_float4x4

    var body: some View {
        Canvas { context, size in
            let camPos = SIMD2<Float>(currentPose.columns.3.x, currentPose.columns.3.z)
            let scale: Float = 26.0 // pixels per meter
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)

            func toScreen(_ worldXZ: SIMD2<Float>) -> CGPoint {
                let rel = worldXZ - camPos
                return CGPoint(
                    x: center.x + CGFloat(rel.x * scale),
                    y: center.y + CGFloat(rel.y * scale)
                )
            }

            // Accumulated points
            for p in points2D {
                let sp = toScreen(p)
                if sp.x >= 0, sp.x <= size.width, sp.y >= 0, sp.y <= size.height {
                    context.fill(
                        Path(CGRect(x: sp.x - 1, y: sp.y - 1, width: 2, height: 2)),
                        with: .color(.mint.opacity(0.65))
                    )
                }
            }

            // Trajectory path
            if trajectoryPoses.count > 1 {
                var path = Path()
                for (i, pose) in trajectoryPoses.enumerated() {
                    let pt = toScreen(SIMD2<Float>(pose.columns.3.x, pose.columns.3.z))
                    if i == 0 {
                        path.move(to: pt)
                    } else {
                        path.addLine(to: pt)
                    }
                }
                context.stroke(path, with: .color(.cyan), lineWidth: 1.5)
            }

            // Active camera frustum cone
            let forwardWorld = currentPose * SIMD4<Float>(0, 0, -0.6, 1)
            let leftWorld = currentPose * SIMD4<Float>(-0.35, 0, -0.6, 1)
            let rightWorld = currentPose * SIMD4<Float>(0.35, 0, -0.6, 1)

            let origin = center
            let leftPt = toScreen(SIMD2<Float>(leftWorld.x, leftWorld.z))
            let rightPt = toScreen(SIMD2<Float>(rightWorld.x, rightWorld.z))
            let fwdPt = toScreen(SIMD2<Float>(forwardWorld.x, forwardWorld.z))

            var cone = Path()
            cone.move(to: origin)
            cone.addLine(to: leftPt)
            cone.addLine(to: rightPt)
            cone.closeSubpath()
            context.fill(cone, with: .color(.yellow.opacity(0.25)))
            context.stroke(cone, with: .color(.yellow), lineWidth: 1.2)

            var dirLine = Path()
            dirLine.move(to: origin)
            dirLine.addLine(to: fwdPt)
            context.stroke(dirLine, with: .color(.yellow.opacity(0.7)), lineWidth: 1)

            // Camera dot
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                with: .color(.yellow)
            )
        }
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
