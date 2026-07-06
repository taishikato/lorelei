//
//  OnboardingView.swift
//  Lorelei
//
//  Guided first-run flow: welcome -> permissions with rationale ->
//  workspace + "hold to talk" reminder. Shown once, gated by
//  LoreleiOnboarding.shouldShow().
//

import AppKit
import SwiftUI

/// Tracks whether the guided first-run flow has been completed.
enum LoreleiOnboarding {
    static let completedDefaultsKey = "hasCompletedLoreleiOnboarding"

    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: completedDefaultsKey)
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedDefaultsKey)
    }
}

struct OnboardingView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var workspaceStore: WorkspaceSettingsStore
    let onFinished: (() -> Void)?

    @State private var step: Int = 0

    init(companionManager: CompanionManager, onFinished: (() -> Void)? = nil) {
        self.companionManager = companionManager
        _workspaceStore = ObservedObject(wrappedValue: companionManager.workspaceSettingsStore)
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                switch step {
                case 0: welcomePage
                case 1: permissionsPage
                default: workspacePage
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            continueButton
        }
        .padding(24)
        .frame(width: 460)
        .background(.regularMaterial)
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            LoreleiFaceView(expression: .neutral, audioLevel: 0)
                .scaleEffect(1.6)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            Text("Welcome to Lorelei")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Lorelei is a hold-to-talk voice control for your Mac. Hold the shortcut, say what you want, and Lorelei drives your Mac through Codex to get it done.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)

            hotkeyReminder
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var hotkeyReminder: some View {
        HStack(spacing: 5) {
            Text("Hold")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            ForEach(BuddyPushToTalkShortcut.currentShortcutOption.keyCapsuleLabels, id: \.self) { keyLabel in
                Text(keyLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(0.14))
                    )
            }

            Text("and speak")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Page 2: Permissions

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lorelei needs a few permissions")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 6) {
                permissionRationale("Microphone", "so Lorelei can hear you.")
                permissionRationale("Accessibility", "so Lorelei can read and press UI on your behalf.")
                permissionRationale("Screen Recording", "as a screenshot fallback when Lorelei needs to see the screen.")
                permissionRationale("Screen Content", "so Lorelei can answer questions about what's on screen.")
            }

            PermissionRowsView(companionManager: companionManager)
        }
    }

    private func permissionRationale(_ title: String, _ rationale: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(rationale)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Page 3: Workspace & finish

    private var workspacePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a workspace")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Lorelei runs Codex commands inside a folder you choose. Pick the project you want to talk to first.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(workspaceStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(workspaceStatusColor)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 0.7)
                    )
            )

            Button {
                deferredAction { chooseWorkspace() }
            } label: {
                Label("Choose Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)

            Text("You can change permissions and the workspace later from the gear icon on the floating toolbar.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Choose Workspace"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK {
            workspaceStore.selectedWorkspacePath = panel.url?.path
        }
    }

    private var workspaceStatusText: String {
        switch workspaceStore.selectedWorkspaceStatus {
        case .notSelected:
            return "No workspace selected"
        case let .validDirectory(path):
            return path
        case let .invalidDirectory(path):
            return "Missing folder: \(path)"
        }
    }

    private var workspaceStatusColor: Color {
        switch workspaceStore.selectedWorkspaceStatus {
        case .notSelected:
            return DS.Colors.textTertiary
        case .validDirectory:
            return DS.Colors.textSecondary
        case .invalidDirectory:
            return DS.Colors.warningText
        }
    }

    // MARK: - Navigation

    private var continueButton: some View {
        HStack {
            Spacer()

            Button {
                deferredAction { advance() }
            } label: {
                Text(continueButtonTitle)
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var continueButtonTitle: String {
        switch step {
        case 0:
            return "Continue"
        case 1:
            return companionManager.allPermissionsGranted ? "Continue" : "Continue anyway"
        default:
            return "Start Using Lorelei"
        }
    }

    private func advance() {
        if step < 2 {
            step += 1
            return
        }

        LoreleiOnboarding.markCompleted()
        LoreleiAnalytics.capture(.onboardingCompleted)
        onFinished?()
    }
}
