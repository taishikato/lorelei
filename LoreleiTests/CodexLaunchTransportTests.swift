//
//  CodexLaunchTransportTests.swift
//  LoreleiTests
//

import Testing
import AppKit
import Combine
import CoreAudio
import Foundation
import CoreGraphics
import ServiceManagement
@testable import Lorelei

@MainActor
struct CodexLaunchTransportTests {

    @Test func launchEnvironmentPrependsNodeInstallPaths() async throws {
        let path = WorkspaceProcessRunner.launchEnvironment()["PATH"] ?? ""

        #expect(path.contains("/opt/homebrew/bin") || path.contains(".nvm/versions/node"))
    }

    @Test func codexLaunchCommandUsesSiblingNodeForNvmInstall() async throws {
        let codexURL = URL(fileURLWithPath: "/Users/taishi/.nvm/versions/node/v22.14.0/bin/codex")
        guard FileManager.default.isExecutableFile(atPath: codexURL.path) else { return }

        let launch = CodexExecutor.makeLaunchCommand(
            codexExecutableURL: codexURL,
            codexArguments: ["exec", "--help"]
        )

        #expect(launch.executableURL.lastPathComponent == "node")
        #expect(launch.arguments.first?.hasSuffix("codex.js") == true)
        #expect(launch.arguments.dropFirst().starts(with: ["exec", "--help"]))
    }

    @Test func codexExecutableLocatorUsesDefaultsOverrideBeforeBundledCLI() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let overrideCodexURL = directoryURL.appendingPathComponent("override/codex")
        let applicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
        let bundledCodexURL = applicationsURL
            .appendingPathComponent("ChatGPT.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/codex")
        try makeExecutable(at: overrideCodexURL)
        try makeExecutable(at: bundledCodexURL)
        let suiteName = "CodexExecutableLocatorOverrideTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(overrideCodexURL.path, forKey: CodexExecutableLocator.executablePathDefaultsKey)

        let locator = CodexExecutableLocator(
            defaults: defaults,
            environment: [:],
            applicationDirectories: [applicationsURL]
        )

        #expect(locator.resolve() == overrideCodexURL)
    }

    @Test func codexExecutableLocatorPrefersChatGPTBundledCLIOverPATH() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let applicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
        let bundledCodexURL = applicationsURL
            .appendingPathComponent("ChatGPT.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/codex")
        let pathDirectoryURL = directoryURL.appendingPathComponent("bin", isDirectory: true)
        let pathCodexURL = pathDirectoryURL.appendingPathComponent("codex")
        try makeExecutable(at: bundledCodexURL)
        try makeExecutable(at: pathCodexURL)
        let defaults = UserDefaults(suiteName: "CodexExecutableLocatorBundledTests")!
        defer { defaults.removePersistentDomain(forName: "CodexExecutableLocatorBundledTests") }

        let locator = CodexExecutableLocator(
            defaults: defaults,
            environment: ["PATH": pathDirectoryURL.path],
            applicationDirectories: [applicationsURL]
        )

        #expect(locator.resolve() == bundledCodexURL)
    }

    @Test func codexExecutableLocatorChecksEachApplicationDirectoryBeforeTheNext() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let systemApplicationsURL = directoryURL.appendingPathComponent("SystemApplications", isDirectory: true)
        let userApplicationsURL = directoryURL.appendingPathComponent("UserApplications", isDirectory: true)
        let systemChatGPTCodexURL = systemApplicationsURL
            .appendingPathComponent("ChatGPT.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/codex")
        let systemCodexAppCodexURL = systemApplicationsURL
            .appendingPathComponent("Codex.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/codex")
        let userChatGPTCodexURL = userApplicationsURL
            .appendingPathComponent("ChatGPT.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/codex")
        let userCodexAppCodexURL = userApplicationsURL
            .appendingPathComponent("Codex.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/codex")
        try makeExecutable(at: systemChatGPTCodexURL)
        try makeExecutable(at: systemCodexAppCodexURL)
        try makeExecutable(at: userChatGPTCodexURL)
        try makeExecutable(at: userCodexAppCodexURL)
        let suiteName = "CodexExecutableLocatorCrossDirectoryTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let locator = CodexExecutableLocator(
            defaults: defaults,
            environment: [:],
            applicationDirectories: [systemApplicationsURL, userApplicationsURL]
        )

        #expect(locator.resolve() == systemChatGPTCodexURL)

        try FileManager.default.removeItem(at: systemChatGPTCodexURL)
        #expect(locator.resolve() == systemCodexAppCodexURL)

        try FileManager.default.removeItem(at: systemCodexAppCodexURL)
        #expect(locator.resolve() == userChatGPTCodexURL)

        try FileManager.default.removeItem(at: userChatGPTCodexURL)
        #expect(locator.resolve() == userCodexAppCodexURL)
    }

    @Test func codexExecutableLocatorFallsBackToCodexAppWithoutChatGPT() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let applicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
        let bundledCodexURL = applicationsURL
            .appendingPathComponent("Codex.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources/codex")
        try makeExecutable(at: bundledCodexURL)
        let suiteName = "CodexExecutableLocatorCodexAppFallbackTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let locator = CodexExecutableLocator(
            defaults: defaults,
            environment: [:],
            applicationDirectories: [applicationsURL]
        )

        #expect(locator.resolve() == bundledCodexURL)
    }

    @Test func codexExecutableLocatorFallsBackToPATHWithoutBundledCLI() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let emptyApplicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
        let pathDirectoryURL = directoryURL.appendingPathComponent("bin", isDirectory: true)
        let pathCodexURL = pathDirectoryURL.appendingPathComponent("codex")
        try makeExecutable(at: pathCodexURL)
        let suiteName = "CodexExecutableLocatorPATHTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let locator = CodexExecutableLocator(
            defaults: defaults,
            environment: ["PATH": pathDirectoryURL.path],
            applicationDirectories: [emptyApplicationsURL]
        )

        #expect(locator.resolve() == pathCodexURL)
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    @Test func appServerLaunchUsesDefaultStdioTransport() async throws {
        let codexURL = URL(fileURLWithPath: "/usr/local/bin/codex")

        let launch = CodexAppServerLaunch.make(
            codexExecutableURL: codexURL
        )

        #expect(launch.executableURL == codexURL)
        #expect(launch.arguments == ["app-server"])
    }

    @Test func stdioTransportRoundTripsOneJSONLineThroughChildProcess() async throws {
        let transport = try await CodexAppServerStdioTransport.make(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )

        try await transport.send(line: "{\"id\":1,\"method\":\"initialize\"}")
        let echoed = try await transport.nextLine()

        #expect(echoed == "{\"id\":1,\"method\":\"initialize\"}")
        await transport.terminate()
    }

    @Test func stdioTransportAppendsExactlyOneNewlinePerSend() async throws {
        let transport = try await CodexAppServerStdioTransport.make(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )

        try await transport.send(line: "{\"a\":1}\n")
        try await transport.send(line: "{\"b\":2}")
        let first = try await transport.nextLine()
        let second = try await transport.nextLine()

        #expect(first == "{\"a\":1}")
        #expect(second == "{\"b\":2}")
        await transport.terminate()
    }

    @Test func stdioTransportReturnsNilAfterChildExits() async throws {
        let transport = try await CodexAppServerStdioTransport.make(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: []
        )

        let line = try await transport.nextLine()

        #expect(line == nil)
        await transport.terminate()
    }
}
