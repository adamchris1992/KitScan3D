import SwiftUI

struct DiagnosticsConsoleView: View {
    @EnvironmentObject var logger: DiagnosticsLogger
    @State private var selectedLevel: LogLevel? = nil

    private var filteredEntries: [LogEntry] {
        guard let selectedLevel else { return logger.entries.reversed() }
        return logger.entries.filter { $0.level == selectedLevel }.reversed()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Filter", selection: $selectedLevel) {
                    Text("All").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(LogLevel?.some(level))
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                List(filteredEntries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.formattedLine)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(for: entry.level))
                    }
                    .listRowBackground(Color.black)
                }
                .listStyle(.plain)
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) {
                        logger.clear()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: logger.exportLogURL()) {
                        Label("Export Log", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .yellow
        case .error: return .red
        }
    }
}
