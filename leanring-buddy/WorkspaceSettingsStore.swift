//
//  WorkspaceSettingsStore.swift
//  leanring-buddy
//
//  Persists the single workspace path selected from the menu bar panel.
//

import Combine
import Foundation

@MainActor
final class WorkspaceSettingsStore: ObservableObject {
    private let defaults: UserDefaults
    private let selectedWorkspacePathKey = "selectedWorkspacePath"

    @Published var selectedWorkspacePath: String? {
        didSet {
            defaults.set(selectedWorkspacePath, forKey: selectedWorkspacePathKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedWorkspacePath = defaults.string(forKey: selectedWorkspacePathKey)
    }
}
