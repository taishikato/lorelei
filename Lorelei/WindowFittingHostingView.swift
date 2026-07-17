//
//  WindowFittingHostingView.swift
//  Lorelei
//
//  Hosting view for content-sized windows (settings, onboarding) that keeps
//  the window fitted to the SwiftUI content without any of SwiftUI's built-in
//  window sizing. Every built-in option runs a SwiftUI graph update inside the
//  window's updateConstraints pass and AppKit throws: the hosting-view size
//  extrema path crashed with the settings window open during edit churn, and
//  hosting-controller preferredContentSize crashed at window open
//  (both owner-reproduced; see plan 033/034 crash anatomy). This view instead
//  re-measures after each layout pass and resizes the window on the next
//  runloop hop, safely outside any constraints update.
//

import AppKit
import SwiftUI

final class WindowFittingHostingView<Content: View>: NSHostingView<Content> {
    private var fitScheduled = false

    override func layout() {
        super.layout()
        scheduleWindowFit()
    }

    private func scheduleWindowFit() {
        guard !fitScheduled, window != nil else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            guard let window = self.window else { return }
            let ideal = self.fittingSize
            let current = window.contentRect(forFrameRect: window.frame).size
            guard ideal.width > 1, ideal.height > 1,
                  abs(current.width - ideal.width) > 0.5
                    || abs(current.height - ideal.height) > 0.5
            else { return }
            // Anchor the top-left corner so growth extends downward, matching
            // how a titled window visually reads.
            let topLeft = CGPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(ideal)
            window.setFrameTopLeftPoint(topLeft)
        }
    }
}
