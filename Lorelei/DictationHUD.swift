//
//  DictationHUD.swift
//  Lorelei
//
//  Transient borderless panel for short dictation status messages.
//

import AppKit
import SwiftUI

@MainActor
final class DictationHUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, durationSeconds: TimeInterval = 1.5) {
        // Both field crashes fired in the display-cycle observer immediately
        // after a synchronous show() from controller continuations. One hop
        // decouples the panel content swap / resize / orderFront from
        // whatever layout pass the caller sits in.
        DispatchQueue.main.async { [weak self] in
            self?.presentNow(message, durationSeconds: durationSeconds)
        }
    }

    private func presentNow(_ message: String, durationSeconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = nil

        let hostingView = NSHostingView(
            rootView: DictationHUDContent(message: message)
        )
        // Manual panel sizing: keep intrinsic measurement for fittingSize but
        // never let the hosting view drive window size extrema - that path
        // re-marks constraints during updateConstraints and AppKit throws
        // (two field crashes; see plan 033).
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 44)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let size = panel.frame.size
            let origin = NSPoint(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.minY + 48
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(durationSeconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

private struct DictationHUDContent: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(DS.Colors.surface3)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }
}
