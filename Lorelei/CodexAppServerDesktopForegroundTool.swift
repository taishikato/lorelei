//
//  CodexAppServerDesktopForegroundTool.swift
//  Lorelei
//
//  Dynamic Codex App Server tool for bringing a target app into the current
//  macOS Space before Computer Use attempts visual inspection.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum CodexAppServerDesktopSpaceDirection: String, Equatable, Sendable {
    case left
    case right
}

struct CodexAppServerDesktopForegroundEnvironment {
    var openURLInApp: @MainActor (
        _ url: URL,
        _ appName: String?,
        _ bundleIdentifier: String?
    ) async -> Bool
    var activateApp: @MainActor (
        _ appName: String?,
        _ bundleIdentifier: String?
    ) async -> CodexAppServerDesktopForegroundActivationResult
    var appHasOnscreenWindow: @MainActor (
        _ appName: String?,
        _ bundleIdentifier: String?
    ) -> Bool
    var switchSpace: @MainActor (_ direction: CodexAppServerDesktopSpaceDirection) async -> Void
    var sleep: @MainActor (_ nanoseconds: UInt64) async -> Void

    static let live = CodexAppServerDesktopForegroundEnvironment(
        openURLInApp: { url, appName, bundleIdentifier in
            await LiveDesktopForegrounding.openURL(url, appName: appName, bundleIdentifier: bundleIdentifier)
        },
        activateApp: { appName, bundleIdentifier in
            await LiveDesktopForegrounding.activateApp(appName: appName, bundleIdentifier: bundleIdentifier)
        },
        appHasOnscreenWindow: { appName, bundleIdentifier in
            LiveDesktopForegrounding.appHasOnscreenWindow(
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
        },
        switchSpace: { direction in
            LiveDesktopForegrounding.switchSpace(direction)
        },
        sleep: { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    )
}

struct CodexAppServerDesktopForegroundActivationResult: Equatable, Sendable {
    let success: Bool
    let waitedNanoseconds: UInt64

    static func success(waitedNanoseconds: UInt64 = 0) -> Self {
        Self(success: true, waitedNanoseconds: waitedNanoseconds)
    }

    static func failure(waitedNanoseconds: UInt64 = 0) -> Self {
        Self(success: false, waitedNanoseconds: waitedNanoseconds)
    }
}

struct CodexAppServerDesktopForegroundTool {
    nonisolated static let spec = CodexAppServerDynamicToolSpec(
        name: "foreground_app",
        namespace: "lorelei",
        description: "Open an optional URL, activate the target app, and bring its normal window into the current macOS Space before Computer Use.",
        inputSchema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "appName": .object([
                    "type": .string("string"),
                    "description": .string("Human-readable app name, for example Google Chrome.")
                ]),
                "bundleIdentifier": .object([
                    "type": .string("string"),
                    "description": .string("macOS bundle identifier, for example com.google.Chrome.")
                ]),
                "url": .object([
                    "type": .string("string"),
                    "description": .string("Optional http or https URL to open in the target app.")
                ]),
                "maxSpaceSwitches": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                    "maximum": .number(20),
                    "description": .string("Maximum number of current-Space switch attempts before failing.")
                ])
            ])
        ])
    )

    private let environment: CodexAppServerDesktopForegroundEnvironment
    private let defaultMaxSpaceSwitches: Int

    init(
        environment: CodexAppServerDesktopForegroundEnvironment = .live,
        defaultMaxSpaceSwitches: Int = 8
    ) {
        self.environment = environment
        self.defaultMaxSpaceSwitches = defaultMaxSpaceSwitches
    }

    @MainActor
    func handle(_ request: CodexAppServerDynamicToolCallRequest) async -> CodexAppServerDynamicToolCallResult {
        guard request.namespace == Self.spec.namespace,
              request.tool == Self.spec.name else {
            return .failure("Unsupported dynamic tool: \(request.namespace.map { "\($0)." } ?? "")\(request.tool)")
        }

        let arguments = ForegroundArguments(
            json: request.arguments,
            defaultMaxSpaceSwitches: defaultMaxSpaceSwitches
        )
        guard arguments.appName != nil || arguments.bundleIdentifier != nil else {
            return .failure("foreground_app requires appName or bundleIdentifier.")
        }
        guard arguments.urlIsValid else {
            return .failure("foreground_app received an invalid URL.")
        }

        if let url = arguments.url {
            let didOpen = await environment.openURLInApp(url, arguments.appName, arguments.bundleIdentifier)
            guard didOpen else {
                return .failure("Could not open \(url.absoluteString) in \(arguments.targetDescription).")
            }
        }

        let activationResult = await environment.activateApp(arguments.appName, arguments.bundleIdentifier)
        guard activationResult.success else {
            return .failure(
                "Could not make \(arguments.targetDescription) the frontmost active app after waiting \(Self.formatWaitSeconds(activationResult.waitedNanoseconds))."
            )
        }

        if environment.appHasOnscreenWindow(arguments.appName, arguments.bundleIdentifier) {
            return .success("\(arguments.targetDescription) is frontmost and onscreen in the current macOS Space.")
        }

        for _ in 0..<arguments.maxSpaceSwitches {
            await environment.switchSpace(.right)
            await environment.sleep(250_000_000)
            let activationResult = await environment.activateApp(arguments.appName, arguments.bundleIdentifier)

            if activationResult.success, environment.appHasOnscreenWindow(arguments.appName, arguments.bundleIdentifier) {
                return .success("\(arguments.targetDescription) is frontmost and onscreen after switching macOS Spaces.")
            }
        }

        return .failure(
            "\(arguments.targetDescription) did not expose an onscreen normal window after \(arguments.maxSpaceSwitches) Space switch attempts."
        )
    }

    private static func formatWaitSeconds(_ nanoseconds: UInt64) -> String {
        let seconds = Double(nanoseconds) / 1_000_000_000
        return String(format: "%.1f seconds", seconds)
    }
}

private struct ForegroundArguments {
    let appName: String?
    let bundleIdentifier: String?
    let url: URL?
    let urlIsValid: Bool
    let maxSpaceSwitches: Int

    init(json: CodexAppServerJSONValue, defaultMaxSpaceSwitches: Int) {
        appName = json.trimmedString(forKey: "appName")
        bundleIdentifier = json.trimmedString(forKey: "bundleIdentifier")

        if let urlString = json.trimmedString(forKey: "url") {
            let parsedURL = URL(string: urlString)
            let scheme = parsedURL?.scheme?.lowercased()
            url = parsedURL
            urlIsValid = parsedURL != nil && (scheme == "http" || scheme == "https")
        } else {
            url = nil
            urlIsValid = true
        }

        let requestedMaxSpaceSwitches = json.int(forKey: "maxSpaceSwitches") ?? defaultMaxSpaceSwitches
        maxSpaceSwitches = max(0, min(requestedMaxSpaceSwitches, 20))
    }

    var targetDescription: String {
        appName ?? bundleIdentifier ?? "target app"
    }
}

private extension CodexAppServerDynamicToolCallResult {
    static func success(_ text: String) -> CodexAppServerDynamicToolCallResult {
        CodexAppServerDynamicToolCallResult(success: true, contentText: text)
    }

    static func failure(_ text: String) -> CodexAppServerDynamicToolCallResult {
        CodexAppServerDynamicToolCallResult(success: false, contentText: text)
    }
}

private extension CodexAppServerJSONValue {
    func trimmedString(forKey key: String) -> String? {
        guard case .object(let object) = self,
              case .string(let value) = object[key] else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func int(forKey key: String) -> Int? {
        guard case .object(let object) = self,
              case .number(let value) = object[key] else {
            return nil
        }
        return Int(value)
    }
}

enum LiveDesktopForegrounding {
    enum ActivationStep: Equatable {
        case yieldActivationToRunningApplication
        case activateRunningApplication
        case openApplicationActivatingBundleURL
        case reResolveRunningApplicationAfterLaunch
        case waitUntilFinishedLaunching
        case setAccessibilityFrontmost
        case retryActivationUntilFrontmostApplication
    }

    private static let launchPollIntervalNanoseconds: UInt64 = 100_000_000
    private static let launchPollTimeoutNanoseconds: UInt64 = 8_000_000_000
    private static let verificationRetryBackoffNanoseconds: [UInt64] = [
        200_000_000,
        400_000_000,
        800_000_000,
        1_600_000_000,
        2_400_000_000,
        2_600_000_000
    ]

    static func activationPlan(isAppAlreadyRunning: Bool) -> [ActivationStep] {
        if isAppAlreadyRunning {
            return [
                .yieldActivationToRunningApplication,
                .activateRunningApplication,
                .openApplicationActivatingBundleURL,
                .reResolveRunningApplicationAfterLaunch,
                .waitUntilFinishedLaunching,
                .setAccessibilityFrontmost,
                .retryActivationUntilFrontmostApplication
            ]
        }
        return [
            .openApplicationActivatingBundleURL,
            .reResolveRunningApplicationAfterLaunch,
            .waitUntilFinishedLaunching,
            .setAccessibilityFrontmost,
            .retryActivationUntilFrontmostApplication
        ]
    }

    static func shouldWaitForFinishedLaunching(isAppAlreadyRunning: Bool) -> Bool {
        !isAppAlreadyRunning
    }

    @MainActor
    static func openURL(
        _ url: URL,
        appName: String?,
        bundleIdentifier: String?
    ) async -> Bool {
        guard let appURL = applicationURL(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return NSWorkspace.shared.open(url)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: configuration
            ) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    @MainActor
    static func activateApp(
        appName: String?,
        bundleIdentifier: String?
    ) async -> CodexAppServerDesktopForegroundActivationResult {
        if let runningApplication = matchingRunningApplications(
            appName: appName,
            bundleIdentifier: bundleIdentifier
        ).first {
            var currentApplication = reResolveRunningApplication(
                runningApplication,
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
            NSApp.yieldActivation(to: currentApplication)
            if !currentApplication.activate(options: [.activateAllWindows]) {
                guard let appURL = runningApplication.bundleURL
                    ?? applicationURL(appName: appName, bundleIdentifier: bundleIdentifier),
                      let openedApplication = await openApplication(at: appURL) else {
                    return .failure()
                }
                currentApplication = reResolveRunningApplication(
                    openedApplication,
                    appName: appName,
                    bundleIdentifier: bundleIdentifier
                )
            }

            let launchWait = await waitUntilFinishedLaunching(
                currentApplication,
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
            currentApplication = launchWait.runningApplication
            let verification = await retryActivationUntilFrontmost(
                currentApplication,
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
            return CodexAppServerDesktopForegroundActivationResult(
                success: verification.success,
                waitedNanoseconds: launchWait.waitedNanoseconds + verification.waitedNanoseconds
            )
        }

        guard let appURL = applicationURL(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return .failure()
        }

        guard let openedApplication = await openApplication(at: appURL) else {
            return .failure()
        }
        var runningApplication = reResolveRunningApplication(
            openedApplication,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
        let launchWait = await waitUntilFinishedLaunching(
            runningApplication,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
        runningApplication = launchWait.runningApplication
        let verification = await retryActivationUntilFrontmost(
            runningApplication,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
        return CodexAppServerDesktopForegroundActivationResult(
            success: verification.success,
            waitedNanoseconds: launchWait.waitedNanoseconds + verification.waitedNanoseconds
        )
    }

    @MainActor
    private static func openApplication(at appURL: URL) async -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { runningApplication, error in
                continuation.resume(returning: error == nil ? runningApplication : nil)
            }
        }
    }

    @MainActor
    private static func setAccessibilityFrontmost(_ runningApplication: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(runningApplication.processIdentifier)
        AXUIElementSetAttributeValue(
            appElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
    }

    @MainActor
    private static func waitUntilFinishedLaunching(
        _ runningApplication: NSRunningApplication,
        appName: String?,
        bundleIdentifier: String?
    ) async -> (runningApplication: NSRunningApplication, waitedNanoseconds: UInt64) {
        var currentApplication = reResolveRunningApplication(
            runningApplication,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
        var waitedNanoseconds: UInt64 = 0

        while !currentApplication.isFinishedLaunching,
              waitedNanoseconds < launchPollTimeoutNanoseconds {
            try? await Task.sleep(nanoseconds: launchPollIntervalNanoseconds)
            waitedNanoseconds += launchPollIntervalNanoseconds
            currentApplication = reResolveRunningApplication(
                currentApplication,
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
        }

        return (currentApplication, waitedNanoseconds)
    }

    @MainActor
    private static func retryActivationUntilFrontmost(
        _ runningApplication: NSRunningApplication,
        appName: String?,
        bundleIdentifier: String?
    ) async -> (success: Bool, waitedNanoseconds: UInt64) {
        var currentApplication = reResolveRunningApplication(
            runningApplication,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
        var waitedNanoseconds: UInt64 = 0
        var retryDelays = verificationRetryBackoffNanoseconds.makeIterator()

        while true {
            NSApp.yieldActivation(to: currentApplication)
            _ = currentApplication.activate(options: [.activateAllWindows])
            setAccessibilityFrontmost(currentApplication)

            if NSWorkspace.shared.frontmostApplication?.processIdentifier == currentApplication.processIdentifier {
                return (true, waitedNanoseconds)
            }

            guard let delay = retryDelays.next() else {
                return (false, waitedNanoseconds)
            }

            try? await Task.sleep(nanoseconds: delay)
            waitedNanoseconds += delay
            currentApplication = reResolveRunningApplication(
                currentApplication,
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
        }
    }

    @MainActor
    private static func reResolveRunningApplication(
        _ runningApplication: NSRunningApplication,
        appName: String?,
        bundleIdentifier: String?
    ) -> NSRunningApplication {
        let matches = matchingRunningApplications(appName: appName, bundleIdentifier: bundleIdentifier)
        if let processMatch = matches.first(where: { $0.processIdentifier == runningApplication.processIdentifier }) {
            return processMatch
        }
        return matches.first ?? runningApplication
    }

    @MainActor
    static func appHasOnscreenWindow(appName: String?, bundleIdentifier: String?) -> Bool {
        let runningApplications = matchingRunningApplications(
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
        let processIDs = Set(runningApplications.map(\.processIdentifier))
        let ownerNameCandidates = ownerNameCandidates(appName: appName, bundleIdentifier: bundleIdentifier)

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        return windows.contains { window in
            guard windowIsNormalLayer(window),
                  windowHasUsefulSize(window) else {
                return false
            }

            if let ownerProcessID = window[kCGWindowOwnerPID as String] as? pid_t,
               processIDs.contains(ownerProcessID) {
                return true
            }

            guard let ownerName = window[kCGWindowOwnerName as String] as? String else {
                return false
            }
            return ownerNameCandidates.contains { candidate in
                ownerName.localizedCaseInsensitiveContains(candidate)
            }
        }
    }

    @MainActor
    static func switchSpace(_ direction: CodexAppServerDesktopSpaceDirection) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyCode: CGKeyCode = direction == .right ? 124 : 123
        let flags: CGEventFlags = .maskControl

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }

    @MainActor
    private static func matchingRunningApplications(
        appName: String?,
        bundleIdentifier: String?
    ) -> [NSRunningApplication] {
        let trimmedAppName = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleMatches = bundleIdentifier.flatMap(NSRunningApplication.runningApplications) ?? []
        let nameMatches = NSWorkspace.shared.runningApplications.filter { application in
            guard let trimmedAppName,
                  let localizedName = application.localizedName else {
                return false
            }

            return localizedName.localizedCaseInsensitiveContains(trimmedAppName)
                || trimmedAppName.localizedCaseInsensitiveContains(localizedName)
        }

        return Array(Dictionary(grouping: bundleMatches + nameMatches, by: \.processIdentifier).values.compactMap(\.first))
    }

    @MainActor
    private static func applicationURL(appName: String?, bundleIdentifier: String?) -> URL? {
        if let bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return appURL
        }

        if let runningApplication = matchingRunningApplications(
            appName: appName,
            bundleIdentifier: bundleIdentifier
        ).first,
           let bundleURL = runningApplication.bundleURL {
            return bundleURL
        }

        guard let appName = appName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appName.isEmpty else {
            return nil
        }

        let candidateNames = applicationNameCandidates(appName)
        let searchDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        ]

        for directory in searchDirectories {
            for candidateName in candidateNames {
                let appURL = directory.appendingPathComponent(candidateName, isDirectory: true)
                if FileManager.default.fileExists(atPath: appURL.path) {
                    return appURL
                }
            }
        }

        return nil
    }

    private static func applicationNameCandidates(_ appName: String) -> [String] {
        let baseName = appName.hasSuffix(".app") ? String(appName.dropLast(4)) : appName
        var candidates = [baseName]
        if baseName.localizedCaseInsensitiveContains("chrome"),
           !candidates.contains(where: { $0 == "Google Chrome" }) {
            candidates.append("Google Chrome")
        }
        return candidates.map { $0.hasSuffix(".app") ? $0 : "\($0).app" }
    }

    private static func ownerNameCandidates(appName: String?, bundleIdentifier: String?) -> [String] {
        var candidates: [String] = []
        if let appName = appName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appName.isEmpty {
            candidates.append(appName)
        }
        if bundleIdentifier == "com.google.Chrome" {
            candidates.append("Google Chrome")
            candidates.append("Chrome")
        }
        return candidates
    }

    private static func windowIsNormalLayer(_ window: [String: Any]) -> Bool {
        guard let layer = window[kCGWindowLayer as String] as? Int else {
            return false
        }
        return layer == 0
    }

    private static func windowHasUsefulSize(_ window: [String: Any]) -> Bool {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else {
            return false
        }

        let width = doubleValue(bounds["Width"])
        let height = doubleValue(bounds["Height"])
        return width >= 40 && height >= 40
    }

    private static func doubleValue(_ value: Any?) -> Double {
        switch value {
        case let value as NSNumber:
            return value.doubleValue
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        default:
            return 0
        }
    }
}
