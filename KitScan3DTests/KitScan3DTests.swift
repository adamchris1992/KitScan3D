import XCTest
import simd
@testable import KitScan3D

final class KitScan3DTests: XCTestCase {
    func testScaledIntrinsics() {
        let intrinsics = simd_float3x3(
            SIMD3<Float>(1000, 0, 0),
            SIMD3<Float>(0, 1000, 0),
            SIMD3<Float>(960, 540, 1)
        )
        let scaled = CameraCalibration.scaledIntrinsics(
            intrinsics,
            from: CGSize(width: 1920, height: 1080),
            to: 3840,
            targetHeight: 2160
        )
        XCTAssertEqual(scaled.columns.0.x, 2000, accuracy: 0.001)
        XCTAssertEqual(scaled.columns.1.y, 2000, accuracy: 0.001)
        XCTAssertEqual(scaled.columns.2.x, 1920, accuracy: 0.001)
        XCTAssertEqual(scaled.columns.2.y, 1080, accuracy: 0.001)
    }

    func testScanAndGoTriggerThresholds() {
        XCTAssertFalse(
            CameraCalibration.shouldCaptureScanAndGoKeyframe(
                elapsedSeconds: 0.1,
                translationMeters: 0.5,
                rotationDegrees: 20,
                minInterval: 0.35,
                minTranslation: 0.12,
                minRotation: 8.0
            )
        )
        XCTAssertTrue(
            CameraCalibration.shouldCaptureScanAndGoKeyframe(
                elapsedSeconds: 0.4,
                translationMeters: 0.15,
                rotationDegrees: 1.0,
                minInterval: 0.35,
                minTranslation: 0.12,
                minRotation: 8.0
            )
        )
    }

    func testVoxelHashSeparatesDistinctCells() {
        let k1 = VoxelHash.key(for: SIMD3<Float>(0.011, 0.021, -0.031), spacing: 0.01)
        let k2 = VoxelHash.key(for: SIMD3<Float>(0.014, 0.024, -0.034), spacing: 0.01)
        let k3 = VoxelHash.key(for: SIMD3<Float>(0.025, 0.021, -0.031), spacing: 0.01)
        XCTAssertEqual(k1, k2)
        XCTAssertNotEqual(k1, k3)
    }
}
