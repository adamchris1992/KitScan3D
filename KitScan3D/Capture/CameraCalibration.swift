import Foundation
import CoreGraphics
import simd

enum CameraCalibration {
    /// Scales ARKit camera intrinsics (defined for `sourceResolution`) to match a target pixel resolution.
    static func scaledIntrinsics(
        _ intrinsics: simd_float3x3,
        from sourceResolution: CGSize,
        to targetWidth: Int,
        targetHeight: Int
    ) -> simd_float3x3 {
        guard sourceResolution.width > 0, sourceResolution.height > 0 else {
            return intrinsics
        }
        let sx = Float(targetWidth) / Float(sourceResolution.width)
        let sy = Float(targetHeight) / Float(sourceResolution.height)

        var scaled = intrinsics
        scaled.columns.0.x *= sx // fx
        scaled.columns.1.y *= sy // fy
        scaled.columns.2.x *= sx // cx
        scaled.columns.2.y *= sy // cy
        return scaled
    }

    /// Computes translation distance (meters) and rotation angle (degrees) between two 4x4 camera transforms.
    static func poseDelta(from a: simd_float4x4, to b: simd_float4x4) -> (translationMeters: Float, rotationDegrees: Float) {
        let posA = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let posB = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        let translation = simd_distance(posA, posB)

        let qA = simd_quatf(a)
        let qB = simd_quatf(b)
        let dotVal = min(1.0, max(-1.0, abs(simd_dot(qA, qB))))
        let angleRad = 2.0 * acos(dotVal)
        let angleDeg = angleRad * (180.0 / .pi)
        return (translation, angleDeg)
    }

    /// Evaluates whether a Scan & Go keyframe should be captured given elapsed time and pose delta.
    static func shouldCaptureScanAndGoKeyframe(
        elapsedSeconds: TimeInterval,
        translationMeters: Float,
        rotationDegrees: Float,
        minInterval: TimeInterval,
        minTranslation: Float,
        minRotation: Float
    ) -> Bool {
        if elapsedSeconds < minInterval {
            return false
        }
        return translationMeters >= minTranslation || rotationDegrees >= minRotation
    }
}
