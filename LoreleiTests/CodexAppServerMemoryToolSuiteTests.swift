//
//  CodexAppServerMemoryToolSuiteTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct CodexAppServerMemoryToolSuiteTests {
    @Test func memoryWriteSpecRequiresReplacementContent() throws {
        let spec = try #require(CodexAppServerMemoryToolSuite.toolSpecs().first)
        guard case .object(let schema) = spec.inputSchema,
              case .object(let properties) = schema["properties"],
              case .object(let fileProperty) = properties["file"] else {
            Issue.record("Expected memory_write object schema.")
            return
        }

        #expect(spec.name == "memory_write")
        #expect(spec.namespace == "lorelei")
        #expect(schema["additionalProperties"] == .bool(false))
        #expect(schema["required"] == .array([.string("file"), .string("content")]))
        #expect(fileProperty["enum"] == .array([.string("profile"), .string("volatile")]))
        #expect(spec.description.contains("Never store secrets"))
    }

    @Test func memoryWriteProfileReplacesProfile() throws {
        let store = LoreleiMemoryStore(
            rootDirectoryURL: try makeTemporaryDirectory().appendingPathComponent("memory", isDirectory: true)
        )

        let result = CodexAppServerMemoryToolSuite.handle(
            memoryWriteRequest(file: "profile", content: "# Profile\n\nPrefers short answers."),
            store: store,
            workspacePath: "/Users/example/project"
        )

        #expect(result.success)
        #expect(textContent(result) == "Memory updated.")
        #expect(store.loadProfile() == "# Profile\n\nPrefers short answers.")
    }

    @Test func memoryWriteVolatileUsesWorkspacePath() throws {
        let store = LoreleiMemoryStore(
            rootDirectoryURL: try makeTemporaryDirectory().appendingPathComponent("memory", isDirectory: true)
        )

        let result = CodexAppServerMemoryToolSuite.handle(
            memoryWriteRequest(file: "volatile", content: "# Project\n\nUses SwiftUI."),
            store: store,
            workspacePath: "/Users/example/project"
        )

        #expect(result.success)
        #expect(store.loadVolatile(forWorkspacePath: "/Users/example/project") == "# Project\n\nUses SwiftUI.")
        #expect(store.loadVolatile(forWorkspacePath: "/Users/example/other") == nil)
    }

    @Test func memoryWriteRejectsInvalidFile() throws {
        let store = LoreleiMemoryStore(
            rootDirectoryURL: try makeTemporaryDirectory().appendingPathComponent("memory", isDirectory: true)
        )

        let result = CodexAppServerMemoryToolSuite.handle(
            memoryWriteRequest(file: "transcript", content: "Do not save this."),
            store: store,
            workspacePath: nil
        )

        #expect(!result.success)
        #expect(textContent(result)?.contains("profile or volatile") == true)
    }

    @Test func memoryWriteRequiresContent() throws {
        let store = LoreleiMemoryStore(
            rootDirectoryURL: try makeTemporaryDirectory().appendingPathComponent("memory", isDirectory: true)
        )
        let request = CodexAppServerDynamicToolCallRequest(
            requestID: 1,
            callID: "call-1",
            namespace: "lorelei",
            tool: "memory_write",
            arguments: .object(["file": .string("profile")])
        )

        let result = CodexAppServerMemoryToolSuite.handle(request, store: store, workspacePath: nil)

        #expect(!result.success)
        #expect(textContent(result)?.contains("requires content") == true)
    }

    private func memoryWriteRequest(file: String, content: String) -> CodexAppServerDynamicToolCallRequest {
        CodexAppServerDynamicToolCallRequest(
            requestID: 1,
            callID: "call-1",
            namespace: "lorelei",
            tool: "memory_write",
            arguments: .object([
                "file": .string(file),
                "content": .string(content)
            ])
        )
    }
}
