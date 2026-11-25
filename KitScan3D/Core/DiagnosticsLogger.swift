import Foundation
import UIKit

enum LogLevel: String, CaseIterable, Codable {
    case debug = "DBG"
    case info = "INF"
    case warning = "WRN"
    case error = "ERR"
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String

    var formattedLine: String {
        let df = DiagnosticsLogger.sharedDateFormatter
        return "[\(df.string(from: timestamp))] [\(level.rawValue)] [\(category)] \(message)"
    }
}

/// Rolling in-memory and file-backed diagnostics logger for on-device debugging without Xcode.
final class DiagnosticsLogger: ObservableObject {
    static let shared = DiagnosticsLogger()

    static let sharedDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    @Published private(set) var entries: [LogEntry] = []

    private let maxEntries = 600
    private let fileQueue = DispatchQueue(label: "com.kitscan3d.diagnostics.file", qos: .utility)
    private let logFileURL: URL
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let logsDir = docs.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logFileURL = logsDir.appendingPathComponent("kitscan3d.log")

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.log(.warning, category: "Memory", "UIApplication didReceiveMemoryWarningNotification")
        }

        log(.info, category: "App", "DiagnosticsLogger initialized -> \(logFileURL.lastPathComponent)")
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func log(_ level: LogLevel, category: String, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        let line = entry.formattedLine + "\n"

        fileQueue.async { [logFileURL] in
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFileURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logFileURL) {
                        defer { try? handle.close() }
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                    }
                } else {
                    try? data.write(to: logFileURL, options: .atomic)
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
        fileQueue.async { [logFileURL] in
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        }
        log(.info, category: "App", "Diagnostics log cleared")
    }

    func exportLogURL() -> URL {
        return logFileURL
    }
}
