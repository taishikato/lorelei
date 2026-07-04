//
//  DesktopActionExecuting.swift
//  Lorelei
//
//  Dynamic desktop action seam for Codex App Server tools.
//

import Foundation

/// A snapshot line tree of the target app's AX elements, plus the IDs handed out.
struct DesktopSnapshotResult: Equatable, Sendable {
    let text: String
    let elementCount: Int
}

enum DesktopElementAction: String, Equatable, Sendable {
    case press
    case focus
    case raise
    case open
    case select
    case showMenu
}

enum DesktopSetTextMode: String, Equatable, Sendable {
    case replace
    case insert
}

struct DesktopActionOutcome: Equatable, Sendable {
    let success: Bool
    let message: String
}

@MainActor
protocol DesktopActionExecuting: AnyObject {
    /// appName nil = frontmost app. Assigns fresh element IDs (e1, e2, ...).
    func snapshot(appName: String?) async -> Result<DesktopSnapshotResult, DesktopActionError>
    func perform(_ action: DesktopElementAction, elementID: String) async -> DesktopActionOutcome
    func setText(_ text: String, elementID: String, mode: DesktopSetTextMode) async -> DesktopActionOutcome
    /// PNG data of the frontmost screen content (Task 2 wires this into a tool).
    func screenshot() async -> Result<Data, DesktopActionError>
}

enum DesktopActionError: Error, Equatable, Sendable {
    case accessibilityPermissionMissing
    case appNotFound(String)
    case staleElementID(String)
    case captureFailed(String)

    var toolMessage: String {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required before desktop actions can inspect or control apps."
        case .appNotFound(let appName):
            return "Could not find a running app named '\(appName)'."
        case .staleElementID(let elementID):
            return "Unknown or stale elementId '\(elementID)'. Call lorelei.desktop_snapshot again before acting."
        case .captureFailed(let message):
            return "Desktop capture failed: \(message)"
        }
    }
}
