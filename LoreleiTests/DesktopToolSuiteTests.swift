//
//  DesktopToolSuiteTests.swift
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
struct DesktopToolSuiteTests {

    @Test func desktopToolSuiteRegistersSnapshotActionAndSetTextSpecs() throws {
        let specs = CodexAppServerDesktopToolSuite.toolSpecs()

        #expect(specs.map(\.namespace) == ["lorelei", "lorelei", "lorelei", "lorelei"])
        #expect(specs.map(\.name) == ["desktop_snapshot", "desktop_action", "set_text", "screenshot"])

        let snapshotSpec = try #require(specs.first { $0.name == "desktop_snapshot" })
        let actionSpec = try #require(specs.first { $0.name == "desktop_action" })
        let setTextSpec = try #require(specs.first { $0.name == "set_text" })
        let screenshotSpec = try #require(specs.first { $0.name == "screenshot" })

        guard case .object(let snapshotSchema) = snapshotSpec.inputSchema,
              case .object(let snapshotProperties) = snapshotSchema["properties"],
              case .object(let actionSchema) = actionSpec.inputSchema,
              case .object(let actionProperties) = actionSchema["properties"],
              case .object(let setTextSchema) = setTextSpec.inputSchema,
              case .object(let setTextProperties) = setTextSchema["properties"] else {
            Issue.record("Expected object schemas with properties.")
            return
        }

        #expect(snapshotSchema["type"] == .string("object"))
        #expect(snapshotProperties["app"] != nil)
        #expect(actionSchema["required"] == .array([.string("elementId"), .string("action")]))
        #expect(setTextSchema["required"] == .array([.string("elementId"), .string("text")]))
        #expect(snapshotSpec.description.contains("[focused]"))
        #expect(actionSpec.description.contains("\"focused\""))
        #expect(setTextSpec.description.contains("\"focused\""))
        #expect(screenshotSpec.description.contains("Fallback"))
        #expect(screenshotSpec.description.contains("lorelei.desktop_snapshot"))

        guard case .object(let actionProperty) = actionProperties["action"],
              case .array(let actionEnum) = actionProperty["enum"],
              case .object(let modeProperty) = setTextProperties["mode"],
              case .array(let modeEnum) = modeProperty["enum"] else {
            Issue.record("Expected enum schemas for action and mode.")
            return
        }

        guard case .object(let actionElementIDProperty) = actionProperties["elementId"],
              case .object(let setTextElementIDProperty) = setTextProperties["elementId"],
              case .string(let actionElementIDDescription) = actionElementIDProperty["description"],
              case .string(let setTextElementIDDescription) = setTextElementIDProperty["description"] else {
            Issue.record("Expected elementId schemas.")
            return
        }

        #expect(actionElementIDDescription.contains("\"focused\""))
        #expect(setTextElementIDDescription.contains("\"focused\""))
        #expect(actionEnum == [
            .string("press"),
            .string("focus"),
            .string("raise"),
            .string("open"),
            .string("select"),
            .string("showMenu")
        ])
        #expect(setTextProperties["text"] != nil)
        #expect(modeEnum == [.string("replace"), .string("insert")])
    }

    @Test func desktopToolSuiteSnapshotReturnsTreeText() async throws {
        let executor = FakeDesktopActionExecutor()

        let defaultResult = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(tool: "desktop_snapshot", arguments: .object([:])),
            executor: executor
        )
        let appResult = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(tool: "desktop_snapshot", arguments: .object(["app": .string("TextEdit")])),
            executor: executor
        )

        #expect(defaultResult.success)
        #expect(defaultResult.contentItems == [.text("[e1] AXWindow \"Demo\" (0,0 100x100)")])
        #expect(appResult.success)
        #expect(appResult.contentItems == [.text("[e1] AXWindow \"Demo\" (0,0 100x100)")])
        #expect(executor.snapshotAppNames == [nil, "TextEdit"])
    }

    @Test func desktopToolSuiteActionResolvesElementAndReportsOutcome() async throws {
        let executor = FakeDesktopActionExecutor()

        let result = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(
                tool: "desktop_action",
                arguments: .object([
                    "elementId": .string("e2"),
                    "action": .string("showMenu")
                ])
            ),
            executor: executor
        )

        #expect(result.success)
        #expect(result.contentItems == [.text("ok")])
        #expect(executor.performCalls.count == 1)
        #expect(executor.performCalls.first?.0 == .showMenu)
        #expect(executor.performCalls.first?.1 == "e2")

        let focusedResult = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(
                tool: "desktop_action",
                arguments: .object([
                    "elementId": .string("focused"),
                    "action": .string("focus")
                ])
            ),
            executor: executor
        )

        #expect(focusedResult.success)
        #expect(executor.performCalls.count == 2)
        #expect(executor.performCalls[1].0 == .focus)
        #expect(executor.performCalls[1].1 == "focused")
    }

    @Test func desktopToolSuiteSetTextDefaultsToReplaceMode() async throws {
        let executor = FakeDesktopActionExecutor()

        let defaultResult = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(
                tool: "set_text",
                arguments: .object([
                    "elementId": .string("e2"),
                    "text": .string("Hello")
                ])
            ),
            executor: executor
        )
        let insertResult = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(
                tool: "set_text",
                arguments: .object([
                    "elementId": .string("e2"),
                    "text": .string(" there"),
                    "mode": .string("insert")
                ])
            ),
            executor: executor
        )

        #expect(defaultResult.success)
        #expect(insertResult.success)
        #expect(executor.setTextCalls.count == 2)
        #expect(executor.setTextCalls[0].0 == "Hello")
        #expect(executor.setTextCalls[0].1 == "e2")
        #expect(executor.setTextCalls[0].2 == .replace)
        #expect(executor.setTextCalls[1].0 == " there")
        #expect(executor.setTextCalls[1].1 == "e2")
        #expect(executor.setTextCalls[1].2 == .insert)

        let focusedResult = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(
                tool: "set_text",
                arguments: .object([
                    "elementId": .string("focused"),
                    "text": .string("Focused body")
                ])
            ),
            executor: executor
        )

        #expect(focusedResult.success)
        #expect(executor.setTextCalls.count == 3)
        #expect(executor.setTextCalls[2].0 == "Focused body")
        #expect(executor.setTextCalls[2].1 == "focused")
        #expect(executor.setTextCalls[2].2 == .replace)
    }

    @Test func desktopToolSuiteReportsStaleElementAsToolFailure() async throws {
        let executor = FakeDesktopActionExecutor()
        executor.outcome = DesktopActionOutcome(
            success: false,
            message: DesktopActionError.staleElementID("e9").toolMessage
        )

        let result = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(
                tool: "desktop_action",
                arguments: .object([
                    "elementId": .string("e9"),
                    "action": .string("press")
                ])
            ),
            executor: executor
        )

        #expect(!result.success)
        #expect(result.contentItems == [.text("Unknown or stale elementId 'e9'. Call lorelei.desktop_snapshot again before acting.")])
    }

    @Test func desktopToolSuiteRejectsUnknownToolName() async throws {
        let executor = FakeDesktopActionExecutor()

        let result = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(tool: "desktop_spin", arguments: .object([:])),
            executor: executor
        )

        #expect(!result.success)
        #expect(textContent(result)?.contains("desktop_spin") == true)
    }

    @Test func desktopToolSuiteScreenshotReturnsImageItem() async throws {
        let executor = FakeDesktopActionExecutor()
        executor.screenshotResult = .success(Data([0x89, 0x50, 0x4e, 0x47]))

        let result = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(tool: "screenshot", arguments: .object([:])),
            executor: executor
        )

        #expect(result.success)
        #expect(result.contentItems.count == 1)
        guard case .image(let dataURL) = result.contentItems.first else {
            Issue.record("Expected screenshot to return an image content item.")
            return
        }
        #expect(dataURL.hasPrefix("data:image/png;base64,"))
    }

    @Test func desktopToolSuiteScreenshotFailureIsToolFailure() async throws {
        let executor = FakeDesktopActionExecutor()
        executor.screenshotResult = .failure(.captureFailed("no permission"))

        let result = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(tool: "screenshot", arguments: .object([:])),
            executor: executor
        )

        #expect(!result.success)
        #expect(textContent(result)?.contains("no permission") == true)
    }

    private func desktopToolRequest(
        tool: String,
        arguments: CodexAppServerJSONValue,
        namespace: String? = "lorelei"
    ) -> CodexAppServerDynamicToolCallRequest {
        CodexAppServerDynamicToolCallRequest(
            requestID: 47,
            callID: "call-1",
            namespace: namespace,
            tool: tool,
            arguments: arguments
        )
    }
}
