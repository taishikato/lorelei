//
//  OverlayWindow.swift
//  Lorelei
//
//  System-wide transparent overlay window for the listening waveform.
//  One OverlayWindow is created per screen so the capsule can follow
//  the cursor across multiple monitors while dictation is active.
//

import AppKit
import SwiftUI

@MainActor
protocol OverlayWindowManaging: AnyObject {
    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager)
    func hideOverlay()
    func fadeOutAndHideOverlay(duration: TimeInterval)
    func isShowingOverlay() -> Bool
}

extension OverlayWindowManaging {
    func fadeOutAndHideOverlay() {
        fadeOutAndHideOverlay(duration: 0.4)
    }
}

class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        // A non-activating panel, not a plain window: panels are allowed to
        // join other apps' fullscreen Spaces, where an NSWindow silently stays
        // behind the fullscreen app even with canJoinAllSpaces +
        // fullScreenAuxiliary (owner-reproduced with a fullscreen Claude.app).
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// SwiftUI view for the listening waveform capsule.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on this screen and only shows the capsule
// while dictation is listening.
struct BlueCursorView: View {
    let screenFrame: CGRect
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // capsule doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?

    private static let listeningCapsuleSize = CGSize(width: 140, height: 34)
    private static let listeningCapsuleCursorSpacing: CGFloat = 18

    static func capsuleOrigin(cursorPoint: CGPoint, capsuleSize: CGSize, screenFrame: CGRect) -> CGPoint {
        let rightOriginX = cursorPoint.x + listeningCapsuleCursorSpacing
        let leftOriginX = cursorPoint.x - listeningCapsuleCursorSpacing - capsuleSize.width
        let unclampedX = rightOriginX + capsuleSize.width > screenFrame.maxX ? leftOriginX : rightOriginX
        let unclampedY = cursorPoint.y - capsuleSize.height / 2

        return CGPoint(
            x: min(max(unclampedX, screenFrame.minX), screenFrame.maxX - capsuleSize.width),
            y: min(max(unclampedY, screenFrame.minY), screenFrame.maxY - capsuleSize.height)
        )
    }

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Blue waveform capsule - visible only while listening.
            GlassEffectContainer {
                BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .frame(width: Self.listeningCapsuleSize.width, height: Self.listeningCapsuleSize.height)
            .opacity(isCursorOnThisScreen && companionManager.runStatus == .listening ? 1 : 0)
            .position(listeningCapsuleCenter)
            .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
            .animation(.easeIn(duration: 0.15), value: companionManager.runStatus)
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private var listeningCapsuleCenter: CGPoint {
        let origin = Self.capsuleOrigin(
            cursorPoint: cursorPosition,
            capsuleSize: Self.listeningCapsuleSize,
            screenFrame: CGRect(origin: .zero, size: screenFrame.size)
        )

        return CGPoint(
            x: origin.x + Self.listeningCapsuleSize.width / 2,
            y: origin.y + Self.listeningCapsuleSize.height / 2
        )
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// Manager for overlay windows - creates one per screen so the listening
// capsule follows the cursor across multiple monitors.
//
// Windows and their SwiftUI hosting views are cached and reused across
// push-to-talk presses. Tearing the content view down synchronously on key
// release crashed the app (EXC_BAD_ACCESS in SwiftUI's button-gesture
// dispatch): the overlay covers the whole screen while listening, so AppKit
// can still hold gesture state pointing into the hosting bridge when the
// window is dismantled. Hiding is orderOut-only; windows are rebuilt only
// when the screen configuration changes, and discarded windows are torn down
// on the next runloop tick.
@MainActor
class OverlayWindowManager: OverlayWindowManaging {
    private var overlayWindows: [OverlayWindow] = []
    private var overlayCacheKey: [String] = []
    private var isOverlayVisible = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        let cacheKey = screens.map { Self.screenCacheKey($0) }
        if overlayWindows.isEmpty || cacheKey != overlayCacheKey {
            discardOverlayWindowsDeferred()

            for screen in screens {
                let window = OverlayWindow(screen: screen)

                let contentView = BlueCursorView(
                    screenFrame: screen.frame,
                    companionManager: companionManager
                )

                let hostingView = NSHostingView(rootView: contentView)
                // No SwiftUI-driven window sizing: the extrema path throws
                // inside updateConstraints on this OS (plan 033/034 crash
                // anatomy). An earlier report that [] stopped this view from
                // rendering was a misdiagnosis - the invisible waveform was
                // the NSWindow-over-fullscreen-Space issue fixed by the
                // NSPanel conversion above.
                hostingView.sizingOptions = []
                hostingView.frame = screen.frame
                window.contentView = hostingView

                overlayWindows.append(window)
            }

            overlayCacheKey = cacheKey
        }

        for window in overlayWindows {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
        isOverlayVisible = true
    }

    func hideOverlay() {
        // orderOut only - the hosting views stay alive so in-flight gesture
        // state cannot dangle. Windows are reused on the next press.
        for window in overlayWindows {
            window.orderOut(nil)
        }
        isOverlayVisible = false
    }

    /// Fades out overlay windows over `duration` seconds, then hides them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        isOverlayVisible = false

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            Task { @MainActor in
                for window in windowsToFade {
                    // A show() that raced the fade resets alpha to 1 - leave
                    // those windows on screen.
                    if window.alphaValue == 0 {
                        window.orderOut(nil)
                    }
                }
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return isOverlayVisible
    }

    private func discardOverlayWindowsDeferred() {
        let discarded = overlayWindows
        overlayWindows = []
        guard !discarded.isEmpty else { return }
        // Tear down one tick later so any gesture dispatch that references
        // the old hosting views finishes first.
        DispatchQueue.main.async {
            for window in discarded {
                window.orderOut(nil)
                window.contentView = nil
            }
        }
    }

    private static func screenCacheKey(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber ?? 0
        return "\(number)-\(NSStringFromRect(screen.frame))"
    }
}
