import SwiftUI

struct HelpCenterView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("1. Camera & Exposure") {
                    HelpRow(
                        title: "AutoMagic Lock",
                        detail: "Meters lighting at scan start and locks exposure and white balance so colors stay consistent across every frame. Tap Locked/Auto on screen to re-meter if lighting changes."
                    )
                    HelpRow(
                        title: "Live Sliders (WB, Shutter, ISO, EV)",
                        detail: "Tap any camera chip at the bottom of the recording screen to adjust it live while watching the camera feed."
                    )
                    HelpRow(
                        title: "FHD vs 4K",
                        detail: "FHD (1920×1440 @ 60 fps) is fast and smooth for most rooms. 4K (3840×2160 @ 30 fps) gives sharper textures for Gaussian Splatting."
                    )
                }

                Section("2. Scanning Technique") {
                    HelpRow(
                        title: "Pause, Move, Resume",
                        detail: "Tap the red square while recording to pause without ending your scan. Walk to a new angle, tap Record to continue, and tap Done when finished."
                    )
                    HelpRow(
                        title: "LiDAR Range",
                        detail: "Best accuracy is between 0.3 m and 5.0 m. Move smoothly and avoid pointing solely at blank featureless walls."
                    )
                }

                Section("3. Multi-Pass & Cropping") {
                    HelpRow(
                        title: "Auto-Merge & Refine",
                        detail: "In Merge & Align, tap Auto-Merge & Refine to tighten camera drift and align multiple passes together automatically."
                    )
                    HelpRow(
                        title: "3D Crop Box",
                        detail: "In the 3D viewer, tap the Crop icon to trim background clutter. Exports automatically respect your crop box."
                    )
                }

                Section("4. Export Formats") {
                    HelpRow(
                        title: "Point Cloud (.ply)",
                        detail: "Standard binary PLY in 1:1 real-world meters (Y-up). Opens in CloudCompare, Blender, and MeshLab."
                    )
                    HelpRow(
                        title: "COLMAP Dataset (.zip)",
                        detail: "Generates images/, sparse/0/cameras.txt, images.txt, points3D.txt, and points3D.ply with exact ARKit-to-COLMAP coordinates—ready for Postshot, Nerfstudio, Brush, and 3DGS trainers."
                    )
                    HelpRow(
                        title: "Portable Bundle (.zip)",
                        detail: "Self-contained archive with manifest.json, RGB frames, 16-bit depth PNGs (mm), and poses in JSON/CSV."
                    )
                    HelpRow(
                        title: "3DGS Splat (.ply Beta)",
                        detail: "Pre-initialized Gaussian Splat PLY (SH DC color, opacity, scale, rotation) for SuperSplat or 3DGS viewers."
                    )
                }
            }
            .navigationTitle("Help Center")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct HelpRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
