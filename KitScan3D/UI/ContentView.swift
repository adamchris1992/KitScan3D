import SwiftUI

struct ContentView: View {
    @StateObject private var captureManager = ARCaptureSessionManager()
    @StateObject private var projectStore = ScanProjectStore.shared
    @State private var engine = MetalPointCloudEngine()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Group {
                if !ARCaptureSessionManager.isLiDARSupported {
                    UnsupportedHardwareView()
                } else if let engine {
                    CaptureView(captureManager: captureManager, engine: engine)
                } else {
                    Text("Metal GPU device unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem {
                Label("Capture", systemImage: "camera.viewfinder")
            }
            .tag(0)

            ProjectsListView(projectStore: projectStore)
                .tabItem {
                    Label("Projects", systemImage: "folder")
                }
                .tag(1)

            DiagnosticsConsoleView()
                .tabItem {
                    Label("Diagnostics", systemImage: "terminal")
                }
                .tag(2)
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

struct ProjectsListView: View {
    @ObservedObject var projectStore: ScanProjectStore
    @State private var newProjectName = ""
    @State private var showNewProjectAlert = false

    var body: some View {
        NavigationStack {
            List {
                if projectStore.projects.isEmpty {
                    ContentUnavailableView(
                        "No Scan Projects Yet",
                        systemImage: "cube.transparent",
                        description: Text("Start a scan in the Capture tab or create a project here.")
                    )
                } else {
                    ForEach(projectStore.projects) { project in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(project.name)
                                    .font(.headline)
                                if projectStore.activeProject?.id == project.id {
                                    Text("Active")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.25))
                                        .clipShape(Capsule())
                                }
                            }
                            Text("\(project.scanIDs.count) scan pass(es) • Updated \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewProjectAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Scan Project", isPresented: $showNewProjectAlert) {
                TextField("Project Name", text: $newProjectName)
                Button("Create") {
                    projectStore.createProject(name: newProjectName)
                    newProjectName = ""
                }
                Button("Cancel", role: .cancel) {
                    newProjectName = ""
                }
            }
        }
    }
}
