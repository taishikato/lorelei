//
//  DictationHUD.swift
//  Lorelei
//
//  Transient borderless panel for short dictation status messages.
//
//  Deliberately pure AppKit: this panel went through the plan 033/034 crash
//  saga (any SwiftUI-driven sizing option keeps NSHostingView's
//  updateConstraints extrema machinery live, which throws when a graph update
//  lands mid-pass) and, with sizing options off, NSHostingView proposed
//  arbitrary narrow widths to the text. A label plus a layer-backed capsule
//  has fully deterministic sizing and no constraint machinery at all.
//

import AppKit
import SwiftUI

@MainActor
final class DictationHUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private static let capsuleHorizontalPadding = DS.Spacing.md
    private static let capsuleVerticalPadding = DS.Spacing.sm

    func show(_ message: String, durationSeconds: TimeInterval = 1.5) {
        // One runloop hop decouples the panel content swap / resize /
        // orderFront from whatever layout pass the caller sits in (the
        // display-cycle observer crashes fired on synchronous shows from
        // controller continuations).
        DispatchQueue.main.async { [weak self] in
            self?.presentNow(message, durationSeconds: durationSeconds)
        }
    }

    private func presentNow(_ message: String, durationSeconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = nil

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(DS.Colors.textPrimary)
        label.lineBreakMode = .byClipping
        let textSize = label.intrinsicContentSize

        let capsuleSize = NSSize(
            width: ceil(textSize.width) + Self.capsuleHorizontalPadding * 2,
            height: ceil(textSize.height) + Self.capsuleVerticalPadding * 2
        )

        let capsule = NSView(frame: NSRect(origin: .zero, size: capsuleSize))
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor(DS.Colors.surface3).cgColor
        capsule.layer?.cornerRadius = DS.CornerRadius.medium
        capsule.layer?.cornerCurve = .continuous
        capsule.layer?.borderWidth = 1
        capsule.layer?.borderColor = NSColor(DS.Colors.borderSubtle).cgColor

        label.frame = NSRect(
            x: Self.capsuleHorizontalPadding,
            y: Self.capsuleVerticalPadding,
            width: ceil(textSize.width),
            height: ceil(textSize.height)
        )
        capsule.addSubview(label)

        panel.contentView = capsule
        panel.setContentSize(capsuleSize)

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
