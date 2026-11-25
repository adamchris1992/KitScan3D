import SwiftUI

@main
struct KitScan3DApp: App {
    @StateObject private var logger = DiagnosticsLogger.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(logger)
                .preferredColorScheme(.dark)
        }
    }
}
