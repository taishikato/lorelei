//
//  ComputerUsePluginLocatorTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct ComputerUsePluginLocatorTests {
    private static let mcpRelativePath =
        "Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
    private static let skillRelativePath = "skills/computer-use/SKILL.md"

    private func makeInstallFixture(versions: [String], completeVersions: [String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cua-locator-\(UUID().uuidString)", isDirectory: true)
        for version in versions {
            let root = base.appendingPathComponent(version, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard completeVersions.contains(version) else { continue }
            let binary = root.appendingPathComponent(Self.mcpRelativePath)
            let skill = root.appendingPathComponent(Self.skillRelativePath)
            try FileManager.default.createDirectory(
                at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: binary.path, contents: Data("bin".utf8))
            FileManager.default.createFile(atPath: skill.path, contents: Data("skill".utf8))
        }
        return base
    }

    @Test func locatesHighestCompleteVersionNumerically() throws {
        let base = try makeInstallFixture(
            versions: ["1.0.9", "1.0.10"],
            completeVersions: ["1.0.9", "1.0.10"]
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let installation = ComputerUsePluginLocator.locate(baseDirectory: base)
        let unwrapped = try #require(installation)
        #expect(unwrapped.version == "1.0.10")
        #expect(unwrapped.pluginRootPath == base.appendingPathComponent("1.0.10").path)
        #expect(unwrapped.mcpBinaryPath.hasSuffix("SkyComputerUseClient"))
        #expect(unwrapped.skillPath.hasSuffix("SKILL.md"))
    }

    @Test func missingBinaryReturnsNil() throws {
        let base = try makeInstallFixture(versions: ["1.0.5"], completeVersions: ["1.0.5"])
        defer { try? FileManager.default.removeItem(at: base) }
        let binary = base.appendingPathComponent("1.0.5").appendingPathComponent(Self.mcpRelativePath)
        try FileManager.default.removeItem(at: binary)
        #expect(ComputerUsePluginLocator.locate(baseDirectory: base) == nil)
    }

    @Test func missingSkillReturnsNil() throws {
        let base = try makeInstallFixture(versions: ["1.0.5"], completeVersions: ["1.0.5"])
        defer { try? FileManager.default.removeItem(at: base) }
        let skill = base.appendingPathComponent("1.0.5").appendingPathComponent(Self.skillRelativePath)
        try FileManager.default.removeItem(at: skill)
        #expect(ComputerUsePluginLocator.locate(baseDirectory: base) == nil)
    }

    @Test func ignoresNonDirectoryVersionEntries() throws {
        let base = try makeInstallFixture(versions: ["1.0.9"], completeVersions: ["1.0.9"])
        defer { try? FileManager.default.removeItem(at: base) }
        FileManager.default.createFile(
            atPath: base.appendingPathComponent("1.0.10").path,
            contents: Data()
        )

        #expect(ComputerUsePluginLocator.locate(baseDirectory: base)?.version == "1.0.9")
    }

    @Test func missingBaseDirectoryReturnsNil() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cua-locator-missing-\(UUID().uuidString)")
        #expect(ComputerUsePluginLocator.locate(baseDirectory: missing) == nil)
    }

    @Test func highestVersionComparesNumericallyNotLexically() {
        #expect(ComputerUsePluginLocator.highestVersion(["1.0.9", "1.0.10"]) == "1.0.10")
        #expect(ComputerUsePluginLocator.highestVersion(["1.0.1000387", "1.0.999999"]) == "1.0.1000387")
        #expect(ComputerUsePluginLocator.highestVersion([]) == nil)
    }

    @Test func defaultBaseDirectoryIsUnderHomeCodexPluginCache() {
        let base = ComputerUsePluginLocator.defaultBaseDirectory()
        #expect(base.path.hasSuffix(".codex/plugins/cache/openai-bundled/computer-use"))
    }
}
