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

    @Test func codexExecutableLocatorUsesDefaultsOverride() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let codexURL = directoryURL.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: codexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codexURL.path
        )
        let defaults = UserDefaults(suiteName: "CodexExecutableLocatorTests")!
        defaults.removePersistentDomain(forName: "CodexExecutableLocatorTests")
        defaults.set(codexURL.path, forKey: CodexExecutableLocator.executablePathDefaultsKey)

        let locator = CodexExecutableLocator(defaults: defaults)

        #expect(locator.resolve() == codexURL)
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
