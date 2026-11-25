import Foundation

enum GaussianSplatExporter {
    /// Exports a standard 3D Gaussian Splat `.ply` initialized from the aligned/cropped point cloud (Beta).
    /// Compatible with SuperSplat, Postshot, and standard 3DGS viewers.
    static func exportGaussianSplatPLY(
        points: [PointVertex],
        voxelSpacing: Float,
        to destinationURL: URL
    ) throws {
        if ProcessInfo.processInfo.thermalState == .critical {
            DiagnosticsLogger.shared.log(.warning, category: "3DGS", "Device thermal state is critical during 3DGS export")
        }

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
            "property float nx",
            "property float ny",
            "property float nz",
            "property float f_dc_0",
            "property float f_dc_1",
            "property float f_dc_2",
            "property float opacity",
            "property float scale_0",
            "property float scale_1",
            "property float scale_2",
            "property float rot_0",
            "property float rot_1",
            "property float rot_2",
            "property float rot_3",
            "end_header"
        ]
        let header = headerLines.joined(separator: "\n") + "\n"

        var data = Data(header.utf8)
        let floatsPerVertex = 17
        data.reserveCapacity(data.count + validPoints.count * floatsPerVertex * 4)

        let shC0: Float = 0.28209479177387814
        let logScale = log(max(0.002, voxelSpacing * 0.75))
        // logit(0.85) = ln(0.85 / 0.15)
        let logitOpacity: Float = log(0.85 / 0.15)

        func appendFloat(_ v: Float) {
            var bits = v.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }

        for pt in validPoints {
            appendFloat(pt.position.0)
            appendFloat(pt.position.1)
            appendFloat(pt.position.2)
            // nx, ny, nz
            appendFloat(0)
            appendFloat(0)
            appendFloat(0)
            // SH DC color
            appendFloat((pt.color.0 - 0.5) / shC0)
            appendFloat((pt.color.1 - 0.5) / shC0)
            appendFloat((pt.color.2 - 0.5) / shC0)
            // opacity
            appendFloat(logitOpacity)
            // scale_0, scale_1, scale_2
            appendFloat(logScale)
            appendFloat(logScale)
            appendFloat(logScale)
            // rot_0, rot_1, rot_2, rot_3 (identity quaternion w, x, y, z)
            appendFloat(1)
            appendFloat(0)
            appendFloat(0)
            appendFloat(0)
        }

        try data.write(to: destinationURL, options: .atomic)
        DiagnosticsLogger.shared.log(.info, category: "3DGS", "Exported \(validPoints.count) Gaussian splats -> \(destinationURL.lastPathComponent)")
    }
}
