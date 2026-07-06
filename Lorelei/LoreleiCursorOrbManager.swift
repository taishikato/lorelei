//
//  LoreleiCursorOrbManager.swift
//  Lorelei
//

import AppKit
import SwiftUI

private final class LoreleiCursorOrbWindow: NSWindow {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class LoreleiCursorOrbManager: DesktopActionVisualizing {
    private var window: NSWindow?
    private var hostingView: NSHostingView<LoreleiCursorOrbView>?
    private var model: LoreleiCursorOrbModel?
    private var cachedScreenFrame: CGRect?
    private var autoHideTask: Task<Void, Never>?
    // Invalidates in-flight fade-out completions: a completion captured under
    // an older generation must not orderOut a window that a newer action has
    // re-shown.
    private var fadeGeneration = 0
    private var wasVisibleBeforeScreenshotConceal = false

    func animateAction(toAXFrame frame: CGRect) async {
        autoHideTask?.cancel()
        autoHideTask = nil

        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let targetPoint = LoreleiCursorOrbGeometry.appKitPoint(
            fromAXFrameCenter: frame,
            primaryScreenHeight: primaryScreenHeight
        )
        guard let targetScreen = screen(containing: targetPoint) ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let model = prepareWindow(for: targetScreen)
        let targetLocalPoint = localPoint(fromAppKitGlobal: targetPoint, screenFrame: targetScreen.frame)

        if !model.isVisible {
            model.position = homePoint(for: targetScreen)
            model.isVisible = true
            showCancellingFade()
            try? await Task.sleep(nanoseconds: 80_000_000)
        } else {
            showCancellingFade()
        }

        let duration = LoreleiCursorOrbGeometry.travelDuration(from: model.position, to: targetLocalPoint)
        withAnimation(.easeInOut(duration: duration)) {
            model.position = targetLocalPoint
        }
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        model.pulseTrigger += 1
        try? await Task.sleep(nanoseconds: 150_000_000)
        scheduleAutoHide()
    }

    func concealForScreenshot() {
        autoHideTask?.cancel()
        autoHideTask = nil
        fadeGeneration += 1
        wasVisibleBeforeScreenshotConceal = model?.isVisible == true && window?.isVisible == true
        window?.alphaValue = 0
        window?.orderOut(nil)
    }

    func revealAfterScreenshot() {
        guard wasVisibleBeforeScreenshotConceal else { return }
        wasVisibleBeforeScreenshotConceal = false
        model?.isVisible = true
        showCancellingFade()
        scheduleAutoHide()
    }

    private func prepareWindow(for screen: NSScreen) -> LoreleiCursorOrbModel {
        if let window,
           let model,
           cachedScreenFrame == screen.frame {
            window.setFrame(screen.frame, display: true)
            return model
        }

        discardWindowDeferred()

        let model = LoreleiCursorOrbModel(position: homePoint(for: screen))
        let contentView = LoreleiCursorOrbView(model: model)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = CGRect(origin: .zero, size: screen.frame.size)

        let window = LoreleiCursorOrbWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.contentView = hostingView
        window.setFrame(screen.frame, display: true)
        window.setFrameOrigin(screen.frame.origin)

        self.window = window
        self.hostingView = hostingView
        self.model = model
        cachedScreenFrame = screen.frame
        return model
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            fadeOutAndHide()
        }
    }

    private func fadeOutAndHide() {
        guard let window else { return }
        let generation = fadeGeneration
        model?.isVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, self.fadeGeneration == generation else { return }
                window.orderOut(nil)
            }
        })
    }

    /// Shows the window at full alpha, interrupting any in-flight fade-out:
    /// a zero-duration animator pass replaces the running alpha animation,
    /// and bumping the generation disarms its pending orderOut completion.
    private func showCancellingFade() {
        guard let window else { return }
        fadeGeneration += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = 1
        }
        window.orderFrontRegardless()
    }

    private func discardWindowDeferred() {
        let discardedWindow = window
        window = nil
        hostingView = nil
        model = nil
        cachedScreenFrame = nil

        guard let discardedWindow else { return }
        DispatchQueue.main.async {
            discardedWindow.orderOut(nil)
            discardedWindow.contentView = nil
        }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func localPoint(fromAppKitGlobal point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(
            x: point.x - screenFrame.origin.x,
            y: screenFrame.maxY - point.y
        )
    }

    private func homePoint(for screen: NSScreen) -> CGPoint {
        let visibleFrame = screen.visibleFrame
        return CGPoint(
            x: visibleFrame.midX - screen.frame.origin.x,
            y: screen.frame.maxY - visibleFrame.maxY + 8
        )
    }
}
