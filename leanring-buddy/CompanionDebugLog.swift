//
//  CompanionDebugLog.swift
//  leanring-buddy
//
//  Small rolling log exposed in the menu bar panel while Lorelei processes.
//

import Foundation

struct CompanionDebugLog: Equatable, Sendable {
    let maxLines: Int
    private(set) var lines: [String]

    init(maxLines: Int = 40, lines: [String] = []) {
        self.maxLines = max(1, maxLines)
        self.lines = Array(lines.suffix(self.maxLines))
    }

    mutating func append(_ line: String) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(trimmedLine.isEmpty ? "(empty)" : trimmedLine)

        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    var text: String {
        guard !lines.isEmpty else { return "No debug events yet" }
        return lines.joined(separator: "\n")
    }
}
