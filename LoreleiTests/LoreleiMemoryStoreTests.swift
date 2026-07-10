//
//  LoreleiMemoryStoreTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct LoreleiMemoryStoreTests {
    @Test func profileAndVolatileRoundTrip() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("memory", isDirectory: true)
        let store = LoreleiMemoryStore(rootDirectoryURL: rootDirectoryURL)

        try store.writeProfile("# Profile\n\nPrefers concise answers.")
        try store.writeVolatile("# Project\n\nUses SwiftUI.", forWorkspacePath: "/Users/example/project")

        #expect(store.loadProfile() == "# Profile\n\nPrefers concise answers.")
        #expect(store.loadVolatile(forWorkspacePath: "/Users/example/project") == "# Project\n\nUses SwiftUI.")
    }

    @Test func workspaceBucketsAreIsolatedAndStable() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("memory", isDirectory: true)
        let store = LoreleiMemoryStore(rootDirectoryURL: rootDirectoryURL)

        try store.writeVolatile("First", forWorkspacePath: "/Users/example/one")
        try store.writeVolatile("Second", forWorkspacePath: "/Users/example/two")
        try store.writeVolatile("First updated", forWorkspacePath: "/Users/example/one")

        #expect(store.loadVolatile(forWorkspacePath: "/Users/example/one") == "First updated")
        #expect(store.loadVolatile(forWorkspacePath: "/Users/example/two") == "Second")

        let workspaceDirectories = try FileManager.default.contentsOfDirectory(
            at: rootDirectoryURL.appendingPathComponent("workspaces", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        #expect(workspaceDirectories.count == 2)
        #expect(workspaceDirectories.allSatisfy { $0.lastPathComponent.count == 16 })
    }

    @Test func nilWorkspaceUsesDefaultBucket() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("memory", isDirectory: true)
        let store = LoreleiMemoryStore(rootDirectoryURL: rootDirectoryURL)

        try store.writeVolatile("Default context", forWorkspacePath: nil)

        #expect(store.loadVolatile(forWorkspacePath: nil) == "Default context")
        #expect(FileManager.default.fileExists(
            atPath: rootDirectoryURL
                .appendingPathComponent("workspaces/default/VOLATILE.md")
                .path
        ))
    }

    @Test func writesTruncateAtUTF8BoundaryWithinSixteenKilobytes() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("memory", isDirectory: true)
        let store = LoreleiMemoryStore(rootDirectoryURL: rootDirectoryURL)
        let content = String(repeating: "a", count: 16_383) + "é"

        try store.writeProfile(content)

        let profileURL = rootDirectoryURL.appendingPathComponent("PROFILE.md")
        let storedData = try Data(contentsOf: profileURL)
        #expect(storedData.count == 16_383)
        #expect(String(data: storedData, encoding: .utf8) == String(repeating: "a", count: 16_383))
    }

    @Test func whitespaceOnlyLoadsReturnNil() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("memory", isDirectory: true)
        let store = LoreleiMemoryStore(rootDirectoryURL: rootDirectoryURL)

        try store.writeProfile(" \n\t ")
        try store.writeVolatile("\n\n", forWorkspacePath: nil)

        #expect(store.loadProfile() == nil)
        #expect(store.loadVolatile(forWorkspacePath: nil) == nil)
    }

    @Test func clearAllRemovesMemoryDirectory() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
            .appendingPathComponent("memory", isDirectory: true)
        let store = LoreleiMemoryStore(rootDirectoryURL: rootDirectoryURL)
        try store.writeProfile("Profile")
        try store.writeVolatile("Context", forWorkspacePath: "/Users/example/project")

        try store.clearAll()

        #expect(store.loadProfile() == nil)
        #expect(store.loadVolatile(forWorkspacePath: "/Users/example/project") == nil)
        #expect(!FileManager.default.fileExists(atPath: rootDirectoryURL.path))
    }
}
