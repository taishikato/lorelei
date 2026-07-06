//
//  PermissionRowsView.swift
//  Lorelei
//
//  The four permission-grant rows shared by the settings panel and the
//  first-run onboarding flow.
//

import AppKit
import AVFoundation
import SwiftUI

struct PermissionRowsView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(spacing: 5) {
            microphonePermissionRow
            accessibilityPermissionRow
            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }
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
                .buttonStyle(PermissionRowButtonStyle())
                .pointerCursor()
            }
        }
        .padding(8)
        .background(rowBackground)
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

/// Mirrors `CompanionPanelView`'s private `PanelButtonStyle(kind: .small)` -
/// duplicated here rather than widening that type's access.
private struct PermissionRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Colors.textOnAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.accent)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
    }
}
