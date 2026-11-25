import Foundation
import simd

enum PLYExporter {
    /// Writes a binary little-endian PLY file (`x, y, z, red, green, blue`) to `destinationURL`.
    static func exportBinaryPLY(points: [PointVertex], to destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let validPoints = points.filter {
            $0.position.0.isFinite && $0.position.1.isFinite && $0.position.2.isFinite
        }

        let headerLines = [
            "ply",
            "format binary_little_endian 1.0",
            "element vertex \(validPoints.count)",
            "property float x",
            "property float y",
            "property float z",
            "property uchar red",
            "property uchar green",
            "property uchar blue",
            "end_header"
        ]
        let header = headerLines.joined(separator: "\n") + "\n"

        var data = Data(header.utf8)
        let recordSize = 15 // 3 * Float32 (12) + 3 * UInt8 (3)
        data.reserveCapacity(data.count + validPoints.count * recordSize)

        for pt in validPoints {
            var x = pt.position.0.bitPattern.littleEndian
            var y = pt.position.1.bitPattern.littleEndian
            var z = pt.position.2.bitPattern.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &z) { data.append(contentsOf: $0) }

            let r = UInt8(max(0, min(255, Int(round(pt.color.0 * 255.0)))))
            let g = UInt8(max(0, min(255, Int(round(pt.color.1 * 255.0)))))
            let b = UInt8(max(0, min(255, Int(round(pt.color.2 * 255.0)))))
            data.append(r)
            data.append(g)
            data.append(b)
        }

        try data.write(to: destinationURL, options: .atomic)
        DiagnosticsLogger.shared.log(.info, category: "Export", "Exported \(validPoints.count) points to \(destinationURL.lastPathComponent)")
    }
}
