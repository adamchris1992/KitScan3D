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

    func testWorldConsistentVoxelSpacing() {
        var settings = CaptureSettings()
        settings.spacingMode = .adaptive
        settings.farClipMeters = 5.0
        let adaptive = VoxelHash.voxelSpacing(for: settings)
        XCTAssertEqual(adaptive, 0.0045, accuracy: 0.0001)

        settings.spacingMode = .manual
        settings.manualSpacingMeters = 0.001
        XCTAssertEqual(VoxelHash.voxelSpacing(for: settings), 0.002, accuracy: 0.0001)
    }

    func testCropBoxContainsAndYaw() {
        var box = CropBox3D(isEnabled: true, centerX: 0, centerY: 0, centerZ: 0, sizeX: 2, sizeY: 2, sizeZ: 2, yawDegrees: 0)
        XCTAssertTrue(box.contains(SIMD3<Float>(0.5, 0.5, 0.5)))
        XCTAssertFalse(box.contains(SIMD3<Float>(1.5, 0.0, 0.0)))

        box.yawDegrees = 45
        XCTAssertTrue(box.contains(SIMD3<Float>(1.1, 0.0, 0.0)) == false)
        XCTAssertTrue(box.contains(SIMD3<Float>(0.6, 0.0, 0.6)))
    }

    func testICPAlignmentRecoversTranslation() {
        var target: [SIMD3<Float>] = []
        for x in Swift.stride(from: Float(-1), through: Float(1), by: Float(0.25)) {
            for y in Swift.stride(from: Float(-1), through: Float(1), by: Float(0.25)) {
                target.append(SIMD3<Float>(x, y, 0.2 * x))
            }
        }
        let offset = SIMD3<Float>(0.08, -0.05, 0.04)
        let source = target.map { $0 - offset }
        let res = PointCloudRegistration.alignICP(source: source, target: target, iterations: 20, maxDistance: 0.3)
        XCTAssertGreaterThanOrEqual(res.inlierCount, 12)
        XCTAssertLessThan(res.rmse, 0.02)
        XCTAssertEqual(res.transform.columns.3.x, offset.x, accuracy: 0.02)
        XCTAssertEqual(res.transform.columns.3.y, offset.y, accuracy: 0.02)
        XCTAssertEqual(res.transform.columns.3.z, offset.z, accuracy: 0.02)
    }
}
