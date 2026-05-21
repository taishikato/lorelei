//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures only the display containing the user's cursor as JPEG data.
    /// This keeps on-demand screen context scoped to the screen the user is
    /// actively referencing instead of capturing secondary displays.
    static func captureCursorScreenAsJPEG() async throws -> CompanionScreenCapture {
        let context = try await captureContext()

        let cursorDisplay = context.content.displays.first { display in
            let frame = context.nsScreenByDisplayID[display.displayID]?.frame ?? display.frame
            return frame.contains(context.mouseLocation)
        } ?? context.content.displays[0]

        guard let capture = try await capture(
            display: cursorDisplay,
            displayIndex: 0,
            displayCount: 1,
            context: context
        ) else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to encode screen capture"])
        }

        return capture
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let context = try await captureContext()

        // Sort displays so the cursor screen is always first
        let sortedDisplays = context.content.displays.sorted { displayA, displayB in
            let frameA = context.nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = context.nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(context.mouseLocation)
            let bContainsCursor = frameB.contains(context.mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            if let capture = try await capture(
                display: display,
                displayIndex: displayIndex,
                displayCount: sortedDisplays.count,
                context: context
            ) {
                capturedScreens.append(capture)
            }
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    private struct CaptureContext {
        let content: SCShareableContent
        let mouseLocation: NSPoint
        let ownAppWindows: [SCWindow]
        let nsScreenByDisplayID: [CGDirectDisplayID: NSScreen]
    }

    private static func captureContext() async throws -> CaptureContext {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        return CaptureContext(
            content: content,
            mouseLocation: mouseLocation,
            ownAppWindows: ownAppWindows,
            nsScreenByDisplayID: nsScreenByDisplayID
        )
    }

    private static func capture(
        display: SCDisplay,
        displayIndex: Int,
        displayCount: Int,
        context: CaptureContext
    ) async throws -> CompanionScreenCapture? {
        // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
        // displayFrame is in the same coordinate system as NSEvent.mouseLocation
        // and the overlay window's screenFrame in BlueCursorView.
        let displayFrame = context.nsScreenByDisplayID[display.displayID]?.frame
            ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                      width: CGFloat(display.width), height: CGFloat(display.height))
        let isCursorScreen = displayFrame.contains(context.mouseLocation)

        let filter = SCContentFilter(display: display, excludingWindows: context.ownAppWindows)

        let configuration = SCStreamConfiguration()
        let maxDimension = 1280
        let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
        if display.width >= display.height {
            configuration.width = maxDimension
            configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
        }

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }

        let screenLabel: String
        if displayCount == 1 {
            screenLabel = "user's screen (cursor is here)"
        } else if isCursorScreen {
            screenLabel = "screen \(displayIndex + 1) of \(displayCount) — cursor is on this screen (primary focus)"
        } else {
            screenLabel = "screen \(displayIndex + 1) of \(displayCount) — secondary screen"
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: screenLabel,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: Int(displayFrame.width),
            displayHeightInPoints: Int(displayFrame.height),
            displayFrame: displayFrame,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )
    }
}
