//
//  LoreleiDiagLog.swift
//  Lorelei
//
//  Debug-only file logger for diagnosing issues in the running app.
//  print() is block-buffered when stdout is redirected and invisible when
//  the app is launched via `open`, so diagnostics go straight to a file.
//

import Foundation

enum LoreleiDiagLog {
    static let path = "/tmp/lorelei-diag.txt"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        #if DEBUG
        let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let fileHandle = FileHandle(forWritingAtPath: path) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            try? fileHandle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
        #endif
    }
}
