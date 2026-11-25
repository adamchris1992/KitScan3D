import SwiftUI
import simd

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
        .background(Color.black)
    }
}

struct ProjectsHomeView: View {
    @ObservedObject var captureManager: ARCaptureSessionManager
    @ObservedObject var projectStore: ScanProjectStore
    @ObservedObject var engine: MetalPointCloudEngine

    @State private var newProjectName = ""
    @State private var showNewProjectAlert = false
    @State private var showDiagnostics = false
    @State private var activeCaptureProject: ScanProjectMetadata?
    @State private var projectToRename: ScanProjectMetadata?
    @State private var renameText = ""
    @State private var projectToDelete: ScanProjectMetadata?

    var body: some View {
        NavigationStack {
            List {
                if projectStore.projects.isEmpty {
                    ContentUnavailableView(
                        "No Scan Projects Yet",
                        systemImage: "cube.transparent",
                        description: Text("Tap + to create a project before starting your first 3D scan.")
                    )
                } else {
                    ForEach(projectStore.projects) { project in
                        NavigationLink {
                            ProjectDetailView(
                                project: project,
                                captureManager: captureManager,
                                engine: engine
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(.headline)
                                Text("\(project.scanIDs.count) pass(es) • \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                projectToDelete = project
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renameText = project.name
                                projectToRename = project
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
            .navigationTitle("KitScan3D")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Label("Diagnostics", systemImage: "terminal")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewProjectAlert = true
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                }
            }
            .alert("New Scan Project", isPresented: $showNewProjectAlert) {
                TextField("Project Name", text: $newProjectName)
                Button("Create & Scan") {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd HH:mm"
                    let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let created = projectStore.createProject(name: name.isEmpty ? "Scan \(df.string(from: Date()))" : name)
                    newProjectName = ""
                    activeCaptureProject = created
                }
                Button("Cancel", role: .cancel) {
                    newProjectName = ""
                }
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
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsConsoleView()
            }
            .fullScreenCover(item: $activeCaptureProject) { project in
                CaptureView(
                    project: project,
                    captureManager: captureManager,
                    engine: engine
                )
            }
            .onAppear {
                projectStore.reloadProjects()
            }
        }
    }
}

struct ProjectDetailView: View {
    let project: ScanProjectMetadata
    @ObservedObject var captureManager: ARCaptureSessionManager
    @ObservedObject var engine: MetalPointCloudEngine
    @Environment(\.dismiss) private var dismiss

    @State private var scans: [ScanSessionMetadata] = []
    @State private var showCapture = false
    @State private var showFullScreen3D = false
    @State private var isLoading3D = false
    @State private var loadedPoses: [simd_float4x4] = []
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var displayTitle: String = ""

    var body: some View {
        List {
            Section {
                Button {
                    showCapture = true
                } label: {
                    Label("Record New Scan Pass", systemImage: "camera.viewfinder")
                        .font(.headline)
                }

                Button {
                    open3DViewer()
                } label: {
                    HStack {
                        Label("View 3D Point Cloud", systemImage: "cube.fill")
                            .font(.headline)
                        if isLoading3D {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(scans.isEmpty || isLoading3D)
            }

            Section("Recorded Passes (\(scans.count))") {
                if scans.isEmpty {
                    Text("No recordings yet. Tap 'Record New Scan Pass' above to start.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scans) { scan in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scan.name)
                                .font(.headline)
                            Text("\(scan.frameCount) keyframes • \(scan.resolutionWidth)x\(scan.resolutionHeight) • \(scan.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
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
        .navigationTitle(displayTitle.isEmpty ? project.name : displayTitle)
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
            scans = ScanProjectStore.shared.loadScans(for: project.id)
        }
        .fullScreenCover(isPresented: $showCapture, onDismiss: {
            scans = ScanProjectStore.shared.loadScans(for: project.id)
        }) {
            CaptureView(
                project: project,
                captureManager: captureManager,
                engine: engine
            )
        }
        .fullScreenCover(isPresented: $showFullScreen3D) {
            FullScreen3DViewerView(
                title: project.name,
                engine: engine,
                trajectoryPoses: loadedPoses,
                currentPose: loadedPoses.last ?? matrix_identity_float4x4
            )
        }
    }

    private func open3DViewer() {
        isLoading3D = true
        engine.loadProjectFromDisk(projectID: project.id, settings: captureManager.settings) { poses in
            loadedPoses = poses
            isLoading3D = false
            showFullScreen3D = true
        }
    }
}

struct FullScreen3DViewerView: View {
    let title: String
    @ObservedObject var engine: MetalPointCloudEngine
    let trajectoryPoses: [simd_float4x4]
    let currentPose: simd_float4x4
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            PointCloud3DMetalView(
                engine: engine,
                trajectoryPoses: trajectoryPoses,
                currentPose: currentPose
            )
            .ignoresSafeArea()

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(title)
                        .font(.subheadline.bold())
                    Text("\(engine.totalPointCount.formatted()) points • Drag to orbit, 2-finger pan, pinch zoom")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding()
        }
    }
}
