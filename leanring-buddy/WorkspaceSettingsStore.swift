//
//  WorkspaceSettingsStore.swift
//  leanring-buddy
//
//  Persists the single workspace path selected from the menu bar panel.
//

import Combine
import Foundation

enum WorkspaceSelectionStatus: Equatable {
    case notSelected
    case validDirectory(String)
    case invalidDirectory(String)
}

@MainActor
final class WorkspaceSettingsStore: ObservableObject {
    static let selectedWorkspacePathDefaultsKey = "selectedWorkspacePath"

    private let defaults: UserDefaults

    @Published var selectedWorkspacePath: String? {
        didSet {
            if let selectedWorkspacePath {
                defaults.set(selectedWorkspacePath, forKey: Self.selectedWorkspacePathDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.selectedWorkspacePathDefaultsKey)
            }
        }
    }

    var selectedWorkspaceStatus: WorkspaceSelectionStatus {
        guard let selectedWorkspacePath else { return .notSelected }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: selectedWorkspacePath,
            isDirectory: &isDirectory
        )

        return exists && isDirectory.boolValue
            ? .validDirectory(selectedWorkspacePath)
            : .invalidDirectory(selectedWorkspacePath)
    }

    var canOpenSelectedWorkspace: Bool {
        if case .validDirectory = selectedWorkspaceStatus {
            return true
        }
        return false
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedWorkspacePath = defaults.string(forKey: Self.selectedWorkspacePathDefaultsKey)
    }

    func clearSelectedWorkspacePath() {
        selectedWorkspacePath = nil
    }
}
