//
//  CompanionPanelView.swift
//  Lorelei
//
//  Compact menu bar control panel for Lorelei.
//

import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var workspaceStore: WorkspaceSettingsStore
    @StateObject private var loginItemController: LoginItemSettingsController

    @MainActor
    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _workspaceStore = ObservedObject(wrappedValue: companionManager.workspaceSettingsStore)
        _loginItemController = StateObject(wrappedValue: LoginItemSettingsController())
    }

    @MainActor
    init(companionManager: CompanionManager, workspaceStore: WorkspaceSettingsStore) {
        self.companionManager = companionManager
        _workspaceStore = ObservedObject(wrappedValue: workspaceStore)
        _loginItemController = StateObject(wrappedValue: LoginItemSettingsController())
    }

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    generalSection
                    workspaceSection
                    voiceSection
                    debugDisclosure
                }
                .padding(12)

                Divider()
                    .background(.white.opacity(0.12))

                footer
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .frame(width: 340)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 10)
        }
        .onAppear {
            loginItemController.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LoreleiFaceView(expression: .neutral, audioLevel: 0)
                .scaleEffect(0.56)
                .frame(width: 34, height: 20)

            Text("Lorelei")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Text(appVersion)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.10))
                )

            Spacer()
        }
    }

    private var generalSection: some View {
        section("General") {
            HStack(spacing: 10) {
                Image(systemName: "powerplug")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at Login")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(loginItemController.presentation.statusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { loginItemController.presentation.isOn },
                        set: { loginItemController.setEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(8)
            .background(rowBackground)
        }
    }

    private var workspaceSection: some View {
        section("Workspace") {
            VStack(alignment: .leading, spacing: 6) {
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
                .background(rowBackground)

                HStack(spacing: 8) {
                    Button {
                        chooseWorkspace()
                    } label: {
                        Label("Choose", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(PanelButtonStyle(kind: .primary))
                    .pointerCursor()

                    Button {
                        openWorkspaceInFinder()
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
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
            VStack(spacing: 5) {
                microphonePermissionRow
                accessibilityPermissionRow
                screenRecordingPermissionRow

                if companionManager.hasScreenRecordingPermission {
                    screenContentPermissionRow
                }
            }
        }
    }

    private var debugDisclosure: some View {
        DisclosureGroup {
            debugBlock
                .padding(.top, 6)
        } label: {
            Text("Debug")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    private var debugBlock: some View {
        ScrollView {
            Text(companionManager.debugLogText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 64, maxHeight: 96)
        .padding(8)
        .background(rowBackground)
    }

    private var footer: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: 10) {
                Spacer()

                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)

                Text("Quit")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            content()
        }
    }

    private func permissionRow(
        title: String,
        iconName: String,
        isGranted: Bool,
        grantAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isGranted ? .secondary : DS.Colors.warning)
                .frame(width: 18)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            if isGranted {
                Text("Granted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.success)
                    .lineLimit(2)
            } else {
                Button("Grant") {
                    grantAction()
                }
                .buttonStyle(PanelButtonStyle(kind: .small))
                .pointerCursor()
            }
        }
        .padding(8)
        .background(rowBackground)
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

    private var appVersion: String {
        "v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.black.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 0.7)
            )
    }

}

struct LoginItemRowPresentation: Equatable {
    let isOn: Bool
    let statusText: String
}

@MainActor
final class LoginItemSettingsController: ObservableObject {
    @Published private(set) var presentation: LoginItemRowPresentation

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        presentation = Self.rowPresentation(for: service.status)
    }

    func refresh() {
        presentation = Self.rowPresentation(for: service.status)
    }

    func setEnabled(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("⚠️ Lorelei: Failed to update login item: \(error)")
        }

        refresh()
    }

    static func rowPresentation(for status: SMAppService.Status) -> LoginItemRowPresentation {
        switch status {
        case .enabled:
            return LoginItemRowPresentation(isOn: true, statusText: "Enabled")
        case .requiresApproval:
            return LoginItemRowPresentation(isOn: false, statusText: "Needs approval in System Settings")
        case .notRegistered:
            return LoginItemRowPresentation(isOn: false, statusText: "Off")
        case .notFound:
            return LoginItemRowPresentation(isOn: false, statusText: "Unavailable")
        @unknown default:
            return LoginItemRowPresentation(isOn: false, statusText: "Unavailable")
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
