import SwiftUI
import simd

private enum AppTheme {
    static let background = Color(red: 0.043, green: 0.047, blue: 0.063)
    static let card = Color(red: 0.082, green: 0.090, blue: 0.118)
    static let cardBorder = Color.white.opacity(0.08)
    static let badge = Color.white.opacity(0.08)
}

struct ContentView: View {
    @StateObject private var captureManager = ARCaptureSessionManager()
    @StateObject private var projectStore = ScanProjectStore.shared
    @State private var engine = MetalPointCloudEngine()

    var body: some View {
        if !ARCaptureSessionManager.isLiDARSupported {
            UnsupportedHardwareView()
        } else if let engine {
            ProjectsHomeView(
                captureManager: captureManager,
                projectStore: projectStore,
                engine: engine
            )
        } else {
            Text("Metal GPU device unavailable.")
                .foregroundStyle(.secondary)
        }
    }
}

struct UnsupportedHardwareView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sensor.tag.radiowaves.forward.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("LiDAR Sensor Required")
                .font(.title2.bold())
            Text("KitScan3D requires an iPhone Pro or iPad Pro with a hardware LiDAR scanner (`ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }
}

struct ProjectsHomeView: View {
    @ObservedObject var captureManager: ARCaptureSessionManager
    @ObservedObject var projectStore: ScanProjectStore
    @ObservedObject var engine: MetalPointCloudEngine

    @State private var showNewProjectSheet = false
    @State private var showDiagnostics = false
    @State private var isEditing = false
    @State private var projectToRename: ScanProjectMetadata?
    @State private var renameText = ""
    @State private var projectToDelete: ScanProjectMetadata?

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Projects")
                            .font(.largeTitle.bold())
                            .padding(.horizontal)
                            .padding(.top, 8)

                        if projectStore.projects.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "folder")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.secondary)
                                Text("No Projects")
                                    .font(.title3.bold())
                                Text("Tap + to create a scan project.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 80)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(projectStore.projects) { project in
                                    HStack(spacing: 12) {
                                        if isEditing {
                                            Button {
                                                projectToDelete = project
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .font(.title3)
                                                    .foregroundStyle(.red)
                                            }
                                        }

                                        NavigationLink {
                                            ProjectDetailView(
                                                project: project,
                                                captureManager: captureManager,
                                                engine: engine
                                            )
                                        } label: {
                                            HStack(spacing: 14) {
                                                ZStack {
                                                    RoundedRectangle(cornerRadius: 12)
                                                        .fill(AppTheme.badge)
                                                        .frame(width: 48, height: 48)
                                                    Image(systemName: "cube.transparent")
                                                        .font(.title3)
                                                        .foregroundStyle(.white.opacity(0.85))
                                                }

                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(project.name)
                                                        .font(.headline)
                                                        .foregroundStyle(.white)
                                                    Text("\(project.scanIDs.count) pass(es) • \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }

                                                Spacer()

                                                if isEditing {
                                                    Button {
                                                        renameText = project.name
                                                        projectToRename = project
                                                    } label: {
                                                        Image(systemName: "pencil")
                                                            .font(.subheadline)
                                                            .padding(8)
                                                            .background(AppTheme.badge, in: Circle())
                                                    }
                                                } else {
                                                    Image(systemName: "chevron.right")
                                                        .font(.caption.bold())
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .padding(14)
                                            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 16)
                                                    .stroke(AppTheme.cardBorder, lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button {
                                                renameText = project.name
                                                projectToRename = project
                                            } label: {
                                                Label("Rename", systemImage: "pencil")
                                            }
                                            Button(role: .destructive) {
                                                projectToDelete = project
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "terminal")
                            .font(.subheadline)
                            .padding(8)
                            .background(AppTheme.card, in: Circle())
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button(isEditing ? "Done" : "Edit") {
                            withAnimation { isEditing.toggle() }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)

                        Button {
                            showNewProjectSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AppTheme.card, in: Capsule())
                }
            }
            .sheet(isPresented: $showNewProjectSheet) {
                NewProjectSheetView { name in
                    projectStore.createProject(name: name)
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsConsoleView()
            }
            .alert("Rename Project", isPresented: Binding(
                get: { projectToRename != nil },
                set: { if !$0 { projectToRename = nil } }
            )) {
                TextField("Project Name", text: $renameText)
                Button("Save") {
                    if let p = projectToRename {
                        projectStore.renameProject(id: p.id, newName: renameText)
                    }
                    projectToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    projectToRename = nil
                }
            }
            .confirmationDialog(
                "Delete Project?",
                isPresented: Binding(
                    get: { projectToDelete != nil },
                    set: { if !$0 { projectToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    if let p = projectToDelete {
                        projectStore.deleteProject(id: p.id)
                    }
                    projectToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    projectToDelete = nil
                }
            } message: {
                Text("This removes all recorded frames and depth data for '\(projectToDelete?.name ?? "")'.")
            }
            .onAppear {
                projectStore.reloadProjects()
            }
        }
    }
}

struct NewProjectSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var nameText = ""
    let onCreate: (String) -> Void

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppTheme.card, in: Capsule())

                    Spacer()
                    Text("New Project")
                        .font(.headline)
                    Spacer()
                    Color.clear.frame(width: 70, height: 1)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppTheme.card)
                        .frame(width: 52, height: 52)
                    Image(systemName: "folder.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Start a New Scan")
                        .font(.title.bold())
                    Text("Organize your LiDAR passes and 3D point clouds together in one project.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("PROJECT NAME")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    TextField("e.g. Living Room, Staircase ...", text: $nameText)
                        .padding(14)
                        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(AppTheme.cardBorder, lineWidth: 1)
                        )
                }

                Button {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd HH:mm"
                    let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onCreate(trimmed.isEmpty ? "Scan \(df.string(from: Date()))" : trimmed)
                    dismiss()
                } label: {
                    Label("Create Project", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)

                Spacer()
            }
            .padding()
        }
    }
}

struct ProjectDetailView: View {
    let project: ScanProjectMetadata
    @ObservedObject var captureManager: ARCaptureSessionManager
    @ObservedObject var engine: MetalPointCloudEngine
    @Environment(\.dismiss) private var dismiss

    @State private var scans: [ScanSessionMetadata] = []
    @State private var showResolutionPicker = false
    @State private var showCapture = false
    @State private var showScansSheet = false
    @State private var showFullScreen3D = false
    @State private var isLoading3D = false
    @State private var loadedPoses: [simd_float4x4] = []
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var displayTitle: String = ""
    @State private var isExportingPLY = false
    @State private var exportedPLYURL: URL?
    @State private var showMergeAlign = false
    @State private var alignmentState = ProjectAlignmentState()

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Hero Preview Card
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack {
                            if !scans.isEmpty && engine.totalPointCount > 0 {
                                PointCloud3DMetalView(
                                    engine: engine,
                                    trajectoryPoses: loadedPoses,
                                    currentPose: loadedPoses.last ?? matrix_identity_float4x4,
                                    showLiveFrustum: false,
                                    showTrajectory: false
                                )
                                .frame(height: 210)
                                .onTapGesture {
                                    showFullScreen3D = true
                                }
                            } else {
                                Color(red: 0.06, green: 0.075, blue: 0.10)
                                    .frame(height: 210)
                                Image(systemName: "cube")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("SCAN PROJECT")
                                .font(.caption2.bold())
                                .tracking(1.2)
                                .foregroundStyle(.secondary)
                            Text(displayTitle.isEmpty ? project.name : displayTitle)
                                .font(.title2.bold())
                            Text("\(scans.count) pass(es) • \(project.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                    }
                    .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(AppTheme.cardBorder, lineWidth: 1)
                    )

                    // Start Capturing Card
                    Button {
                        showResolutionPicker = true
                    } label: {
                        ProjectActionRow(
                            icon: "camera.fill",
                            iconColor: .white,
                            badgeColor: AppTheme.badge,
                            title: "Start Capturing",
                            subtitle: "Continuous Scan & Go or manual single shots"
                        )
                    }
                    .buttonStyle(.plain)

                    if !scans.isEmpty {
                        // View Scans Card
                        Button {
                            showScansSheet = true
                        } label: {
                            ProjectActionRow(
                                icon: "square.3.layers.3d",
                                iconColor: .white,
                                badgeColor: AppTheme.badge,
                                title: "View Scans",
                                subtitle: "\(scans.count) recorded pass(es) • inspect 3D point clouds"
                            )
                        }
                        .buttonStyle(.plain)

                        // Merge & Align Card
                        Button {
                            showMergeAlign = true
                        } label: {
                            ProjectActionRow(
                                icon: "square.stack.3d.up",
                                iconColor: .white,
                                badgeColor: AppTheme.badge,
                                title: "Merge & Align",
                                subtitle: "Automatically combine & sharpen passes"
                            )
                        }
                        .buttonStyle(.plain)

                        // Export PLY Card
                        Button {
                            exportPLY()
                        } label: {
                            ProjectActionRow(
                                icon: "square.and.arrow.up",
                                iconColor: .white,
                                badgeColor: Color.blue.opacity(0.28),
                                title: isExportingPLY ? "Exporting PLY..." : "Export PLY",
                                subtitle: "Save or share binary .ply point cloud"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isExportingPLY)
                    }

                    // Delete Project Card
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        ProjectActionRow(
                            icon: "trash",
                            iconColor: .red,
                            badgeColor: Color.red.opacity(0.16),
                            title: "Delete Project",
                            subtitle: "Remove this project and its recordings"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }

            if showResolutionPicker {
                ResolutionPickerOverlay(
                    onSelect: { res in
                        captureManager.applyResolution(res)
                        showResolutionPicker = false
                        showCapture = true
                    },
                    onCancel: {
                        showResolutionPicker = false
                    }
                )
            }
        }
        .navigationTitle("Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = displayTitle.isEmpty ? project.name : displayTitle
                        showRenameAlert = true
                    } label: {
                        Label("Rename Project", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Project", isPresented: $showRenameAlert) {
            TextField("Project Name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    ScanProjectStore.shared.renameProject(id: project.id, newName: trimmed)
                    displayTitle = trimmed
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete Project?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                ScanProjectStore.shared.deleteProject(id: project.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all recorded frames and depth data for '\(displayTitle.isEmpty ? project.name : displayTitle)'.")
        }
        .onAppear {
            displayTitle = project.name
            reloadProjectPreview()
        }
        .sheet(isPresented: $showScansSheet, onDismiss: {
            reloadProjectPreview()
        }) {
            ProjectScansSheetView(
                project: project,
                projectName: displayTitle.isEmpty ? project.name : displayTitle,
                scans: $scans,
                engine: engine,
                captureSettings: captureManager.settings
            )
        }
        .fullScreenCover(isPresented: $showCapture, onDismiss: {
            reloadProjectPreview()
        }) {
            CaptureView(
                project: project,
                captureManager: captureManager,
                engine: engine
            )
        }
        .fullScreenCover(isPresented: $showFullScreen3D) {
            FullScreen3DViewerView(
                projectID: project.id,
                title: displayTitle.isEmpty ? project.name : displayTitle,
                engine: engine,
                trajectoryPoses: loadedPoses,
                currentPose: loadedPoses.last ?? matrix_identity_float4x4,
                alignmentState: $alignmentState,
                onAlignmentUpdated: { poses in
                    loadedPoses = poses
                }
            )
        }
        .sheet(isPresented: $showMergeAlign) {
            MergeAlignSheet(
                project: project,
                scans: scans,
                engine: engine,
                captureSettings: captureManager.settings,
                alignmentState: $alignmentState,
                onStateChanged: { poses in
                    loadedPoses = poses
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { exportedPLYURL != nil },
            set: { if !$0 { exportedPLYURL = nil } }
        )) {
            if let url = exportedPLYURL {
                ShareSheet(items: [url])
            }
        }
    }

    private func exportPLY() {
        isExportingPLY = true
        let safeName = (displayTitle.isEmpty ? project.name : displayTitle)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let outURL = ScanProjectStore.shared
            .projectDirectory(for: project.id)
            .appendingPathComponent("exports/\(safeName).ply")

        engine.loadProjectFromDisk(projectID: project.id, settings: captureManager.settings) { _ in
            engine.exportCurrentPointsSnapshot { points in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try PLYExporter.exportBinaryPLY(points: points, to: outURL)
                        DispatchQueue.main.async {
                            isExportingPLY = false
                            exportedPLYURL = outURL
                        }
                    } catch {
                        DiagnosticsLogger.shared.log(.error, category: "Export", "PLY export failed: \(error.localizedDescription)")
                        DispatchQueue.main.async {
                            isExportingPLY = false
                        }
                    }
                }
            }
        }
    }

    private func reloadProjectPreview() {
        alignmentState = ScanProjectStore.shared.loadAlignmentState(for: project.id)
        scans = ScanProjectStore.shared.loadScans(for: project.id)
        if !scans.isEmpty && !isLoading3D {
            isLoading3D = true
            engine.loadProjectFromDisk(projectID: project.id, settings: captureManager.settings) { poses in
                loadedPoses = poses
                isLoading3D = false
            }
        }
    }
}

struct ProjectActionRow: View {
    let icon: String
    let iconColor: Color
    let badgeColor: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(badgeColor)
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppTheme.cardBorder, lineWidth: 1)
        )
    }
}

struct ResolutionPickerOverlay: View {
    let onSelect: (ResolutionPreset) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 18) {
                Text("Choose Capture Resolution")
                    .font(.title3.bold())
                Text("Select image quality before starting the camera.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button {
                        onSelect(.fullHD1080p)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "viewfinder")
                                .font(.title2)
                            Text("FHD")
                                .font(.headline)
                            Text("1920 × 1440 • 60 fps")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSelect(.uhd4K)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "sparkles.tv")
                                .font(.title2)
                            Text("4K")
                                .font(.headline)
                            Text("3840 × 2160 • 30 fps")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(AppTheme.cardBorder, lineWidth: 1)
            )
            .padding(24)
        }
    }
}

struct ProjectScansSheetView: View {
    let project: ScanProjectMetadata
    let projectName: String
    @Binding var scans: [ScanSessionMetadata]
    @ObservedObject var engine: MetalPointCloudEngine
    let captureSettings: CaptureSettings
    @Environment(\.dismiss) private var dismiss

    @State private var showFullScreen3D = false
    @State private var loadedPoses: [simd_float4x4] = []
    @State private var isLoading = false
    @State private var alignmentState = ProjectAlignmentState()

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                List {
                    Section {
                        Button {
                            open3D()
                        } label: {
                            HStack {
                                Label("Inspect Combined 3D Point Cloud", systemImage: "cube.fill")
                                    .font(.headline)
                                Spacer()
                                if isLoading {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(scans.isEmpty || isLoading)
                        .listRowBackground(AppTheme.card)
                    }

                    Section("Captures (\(scans.count))") {
                        if scans.isEmpty {
                            Text("No captures yet.")
                                .foregroundStyle(.secondary)
                                .listRowBackground(AppTheme.card)
                        } else {
                            ForEach(scans) { scan in
                                Button {
                                    open3D()
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(AppTheme.badge)
                                                .frame(width: 44, height: 44)
                                            Image(systemName: "cube.transparent")
                                                .foregroundStyle(.white)
                                        }
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(scan.name)
                                                .font(.headline)
                                                .foregroundStyle(.white)
                                            Text("\(scan.frameCount) frames • \(scan.resolutionWidth)×\(scan.resolutionHeight) • \(scan.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.bold())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .listRowBackground(AppTheme.card)
                            }
                            .onDelete { offsets in
                                for idx in offsets {
                                    ScanProjectStore.shared.deleteScan(projectID: project.id, scanID: scans[idx].id)
                                }
                                scans.remove(atOffsets: offsets)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            .fullScreenCover(isPresented: $showFullScreen3D) {
                FullScreen3DViewerView(
                    projectID: project.id,
                    title: projectName,
                    engine: engine,
                    trajectoryPoses: loadedPoses,
                    currentPose: loadedPoses.last ?? matrix_identity_float4x4,
                    alignmentState: $alignmentState,
                    onAlignmentUpdated: { poses in
                        loadedPoses = poses
                    }
                )
            }
        }
    }

    private func open3D() {
        isLoading = true
        alignmentState = ScanProjectStore.shared.loadAlignmentState(for: project.id)
        engine.loadProjectFromDisk(projectID: project.id, settings: captureSettings) { poses in
            loadedPoses = poses
            isLoading = false
            showFullScreen3D = true
        }
    }
}

struct FullScreen3DViewerView: View {
    let projectID: UUID
    let title: String
    @ObservedObject var engine: MetalPointCloudEngine
    let trajectoryPoses: [simd_float4x4]
    let currentPose: simd_float4x4
    @Binding var alignmentState: ProjectAlignmentState
    var onAlignmentUpdated: (([simd_float4x4]) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var showTrajectory = true
    @State private var showCameraFrustums = false
    @State private var showCropControls = false
    @State private var pointSize: Float = 3.4

    var body: some View {
        ZStack {
            PointCloud3DMetalView(
                engine: engine,
                trajectoryPoses: trajectoryPoses,
                currentPose: currentPose,
                showLiveFrustum: false,
                showTrajectory: showTrajectory,
                showCameraFrustums: showCameraFrustums,
                cropBox: alignmentState.cropBox,
                pointSize: pointSize
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(title)
                            .font(.subheadline.bold())
                        Text("\(engine.totalPointCount.formatted()) points")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .padding()

                HStack {
                    VStack(spacing: 12) {
                        Button {
                            showTrajectory.toggle()
                        } label: {
                            Image(systemName: showTrajectory ? "point.topleft.down.curvedto.point.bottomright.up.fill" : "point.topleft.down.curvedto.point.bottomright.up")
                                .font(.subheadline)
                                .frame(width: 42, height: 42)
                                .background(showTrajectory ? Color.accentColor.opacity(0.4) : Color.black.opacity(0.45), in: Circle())
                        }

                        Button {
                            showCameraFrustums.toggle()
                            if showCameraFrustums { showTrajectory = true }
                        } label: {
                            Image(systemName: "camera.viewfinder")
                                .font(.subheadline)
                                .frame(width: 42, height: 42)
                                .background(showCameraFrustums ? Color.accentColor.opacity(0.4) : Color.black.opacity(0.45), in: Circle())
                        }

                        Button {
                            withAnimation { showCropControls.toggle() }
                        } label: {
                            Image(systemName: "crop")
                                .font(.subheadline)
                                .frame(width: 42, height: 42)
                                .background((showCropControls || alignmentState.cropBox.isEnabled) ? Color.orange.opacity(0.55) : Color.black.opacity(0.45), in: Circle())
                        }
                    }
                    .padding(.leading, 14)

                    Spacer()
                }

                Spacer()

                if showCropControls {
                    CropBoxControlsPanel(
                        cropBox: $alignmentState.cropBox,
                        onFitToScan: {
                            engine.computeCloudBounds(state: alignmentState) { center, size in
                                alignmentState.cropBox.centerX = center.x
                                alignmentState.cropBox.centerY = center.y
                                alignmentState.cropBox.centerZ = center.z
                                alignmentState.cropBox.sizeX = size.x
                                alignmentState.cropBox.sizeY = size.y
                                alignmentState.cropBox.sizeZ = size.z
                                alignmentState.cropBox.yawDegrees = 0
                                alignmentState.cropBox.isEnabled = true
                                applyAndSaveCrop()
                            }
                        },
                        onChanged: {
                            applyAndSaveCrop()
                        }
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func applyAndSaveCrop() {
        ScanProjectStore.shared.saveAlignmentState(alignmentState, for: projectID)
        engine.applyAlignmentState(alignmentState) { poses in
            onAlignmentUpdated?(poses)
        }
    }
}

struct CropBoxControlsPanel: View {
    @Binding var cropBox: CropBox3D
    let onFitToScan: () -> Void
    let onChanged: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("3D Crop Box", isOn: $cropBox.isEnabled)
                    .font(.subheadline.bold())
                    .onChange(of: cropBox.isEnabled) { _, _ in onChanged() }

                Spacer()

                Button("Fit to Scan") {
                    onFitToScan()
                }
                .font(.caption.bold())
                .buttonStyle(.bordered)
            }

            if cropBox.isEnabled {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Center X: %.2f m", cropBox.centerX))
                            .font(.caption2)
                        Slider(value: $cropBox.centerX, in: -10...10, step: 0.05)
                            .onChange(of: cropBox.centerX) { _, _ in onChanged() }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Size X: %.2f m", cropBox.sizeX))
                            .font(.caption2)
                        Slider(value: $cropBox.sizeX, in: 0.3...20, step: 0.1)
                            .onChange(of: cropBox.sizeX) { _, _ in onChanged() }
                    }
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Center Y: %.2f m", cropBox.centerY))
                            .font(.caption2)
                        Slider(value: $cropBox.centerY, in: -10...10, step: 0.05)
                            .onChange(of: cropBox.centerY) { _, _ in onChanged() }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Size Y: %.2f m", cropBox.sizeY))
                            .font(.caption2)
                        Slider(value: $cropBox.sizeY, in: 0.3...20, step: 0.1)
                            .onChange(of: cropBox.sizeY) { _, _ in onChanged() }
                    }
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Center Z: %.2f m", cropBox.centerZ))
                            .font(.caption2)
                        Slider(value: $cropBox.centerZ, in: -10...10, step: 0.05)
                            .onChange(of: cropBox.centerZ) { _, _ in onChanged() }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Size Z: %.2f m", cropBox.sizeZ))
                            .font(.caption2)
                        Slider(value: $cropBox.sizeZ, in: 0.3...20, step: 0.1)
                            .onChange(of: cropBox.sizeZ) { _, _ in onChanged() }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Rotate Yaw: %.0f°", cropBox.yawDegrees))
                        .font(.caption2)
                    Slider(value: $cropBox.yawDegrees, in: -180...180, step: 1)
                        .onChange(of: cropBox.yawDegrees) { _, _ in onChanged() }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
