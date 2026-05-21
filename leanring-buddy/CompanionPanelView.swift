//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  Compact menu bar control panel for Lorelei.
//

import AppKit
import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @StateObject private var workspaceStore: WorkspaceSettingsStore

    @MainActor
    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _workspaceStore = StateObject(wrappedValue: WorkspaceSettingsStore())
    }

    @MainActor
    init(companionManager: CompanionManager, workspaceStore: WorkspaceSettingsStore) {
        self.companionManager = companionManager
        _workspaceStore = StateObject(wrappedValue: workspaceStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 16) {
                workspaceSection
                voiceSection
                runSection
            }
            .padding(16)

            Divider()
                .background(DS.Colors.borderSubtle)

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Lorelei")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            statusChip

            Spacer()

            Button {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)

            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(DS.Colors.surface2)
        )
        .overlay(
            Capsule()
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.6)
        )
    }

    private var workspaceSection: some View {
        section("Workspace") {
            VStack(alignment: .leading, spacing: 10) {
                Text(workspaceStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(workspaceStatusColor)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.6)
                    )

                HStack(spacing: 8) {
                    Button("Choose") {
                        chooseWorkspace()
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary))
                    .pointerCursor()

                    Button("Open") {
                        openWorkspaceInFinder()
                    }
                    .buttonStyle(PanelButtonStyle(kind: .secondary))
                    .disabled(!workspaceStore.canOpenSelectedWorkspace)
                    .pointerCursor(isEnabled: workspaceStore.canOpenSelectedWorkspace)
                }
            }
        }
    }

    private var voiceSection: some View {
        section("Voice") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hold Control+Option to talk.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                VStack(spacing: 2) {
                    microphonePermissionRow
                    accessibilityPermissionRow
                    screenRecordingPermissionRow

                    if companionManager.hasScreenRecordingPermission {
                        screenContentPermissionRow
                    }
                }

                fieldBlock(
                    title: "Last Transcript",
                    value: companionManager.lastTranscript ?? "No transcript yet"
                )
            }
        }
    }

    private var runSection: some View {
        section("Run") {
            VStack(alignment: .leading, spacing: 10) {
                fieldBlock(
                    title: "Latest Result",
                    value: companionManager.latestResultSummary ?? "No result yet"
                )

                fieldBlock(
                    title: "Pending Confirmation",
                    value: companionManager.pendingConfirmationTitle ?? "No pending confirmation"
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var microphonePermissionRow: some View {
        permissionRow(
            title: "Microphone",
            iconName: "mic",
            isGranted: companionManager.hasMicrophonePermission
        ) {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        permissionRow(
            title: "Accessibility",
            iconName: "hand.raised",
            isGranted: companionManager.hasAccessibilityPermission
        ) {
            WindowPositionManager.requestAccessibilityPermission()
        }
    }

    private var screenRecordingPermissionRow: some View {
        permissionRow(
            title: "Screen Recording",
            iconName: "rectangle.dashed.badge.record",
            isGranted: companionManager.hasScreenRecordingPermission
        ) {
            WindowPositionManager.requestScreenRecordingPermission()
        }
    }

    private var screenContentPermissionRow: some View {
        permissionRow(
            title: "Screen Content",
            iconName: "eye",
            isGranted: companionManager.hasScreenContentPermission
        ) {
            companionManager.requestScreenContentPermission()
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            content()
        }
    }

    private func fieldBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Text(value)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.6)
        )
    }

    private func permissionRow(
        title: String,
        iconName: String,
        isGranted: Bool,
        grantAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                .frame(width: 16)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            if isGranted {
                Text("Granted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.success)
            } else {
                Button("Grant") {
                    grantAction()
                }
                .buttonStyle(PanelButtonStyle(kind: .small))
                .pointerCursor()
            }
        }
        .padding(.vertical, 5)
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

    private func openWorkspaceInFinder() {
        guard case let .validDirectory(path) = workspaceStore.selectedWorkspaceStatus else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
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

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        switch companionManager.voiceState {
        case .idle:
            return companionManager.allPermissionsGranted ? DS.Colors.success : DS.Colors.warning
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        guard companionManager.allPermissionsGranted else { return "Setup" }

        switch companionManager.voiceState {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }
}

private struct PanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    enum Kind {
        case primary
        case secondary
        case small
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: kind == .small ? 11 : 12, weight: .semibold))
            .foregroundColor(foregroundColor)
            .padding(.horizontal, kind == .small ? 10 : 12)
            .padding(.vertical, kind == .small ? 4 : 7)
            .frame(maxWidth: kind == .small ? nil : .infinity)
            .background(background(configuration: configuration))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary, .small:
            return DS.Colors.textOnAccent
        case .secondary:
            return DS.Colors.textSecondary
        }
    }

    private func background(configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(kind == .secondary ? DS.Colors.borderSubtle : Color.clear, lineWidth: 0.7)
            )
    }

    private var fillColor: Color {
        switch kind {
        case .primary, .small:
            return DS.Colors.accent
        case .secondary:
            return DS.Colors.surface2
        }
    }
}
