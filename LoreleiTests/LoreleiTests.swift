//
//  LoreleiTests.swift
//  LoreleiTests
//
//  Created by thorfinn on 3/2/26.
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
struct LoreleiTests {

    @Test func appServerInitializedNotificationMatchesGeneratedProtocolShape() throws {
        let notification = CodexAppServerProtocol.initializedNotification()

        #expect(notification["method"] as? String == "initialized")
        #expect(!notification.keys.contains("params"))
    }

    @Test func appServerTurnStartIncludesTextElementsAndGranularApprovalPolicy() throws {
        let request = CodexAppServerProtocol.turnStartRequest(
            id: 3,
            threadID: "thread-1",
            prompt: "open TextEdit",
            cwd: "/Users/example"
        )
        let params = try #require(request["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])
        let textInput = try #require(input.first)
        let approvalPolicy = try #require(params["approvalPolicy"] as? [String: Any])
        let granular = try #require(approvalPolicy["granular"] as? [String: Any])

        #expect(textInput["type"] as? String == "text")
        #expect(textInput["text"] as? String == "open TextEdit")
        #expect((textInput["text_elements"] as? [Any])?.isEmpty == true)
        #expect(granular["sandbox_approval"] as? Bool == true)
        #expect(granular["rules"] as? Bool == true)
        #expect(granular["skill_approval"] as? Bool == true)
        #expect(granular["request_permissions"] as? Bool == true)
        #expect(granular["mcp_elicitations"] as? Bool == true)
    }

    @Test func appServerTurnStartRequestPinsModelToGPT55() throws {
        let request = CodexAppServerProtocol.turnStartRequest(
            id: 3,
            threadID: "thread-1",
            prompt: "open Gmail",
            cwd: "/Users/example"
        )
        let params = try #require(request["params"] as? [String: Any])

        #expect(params["model"] as? String == "gpt-5.5")
    }

    @Test func appServerTurnStartRequestEncodesSandboxPolicyAndLocalImage() throws {
        let request = CodexAppServerProtocol.turnStartRequest(
            id: 3,
            threadID: "thread-1",
            prompt: "look at my screen",
            cwd: "/Users/example",
            sandboxPolicy: "readOnly",
            extraInput: [.localImage(path: "/tmp/lorelei-screen.jpg")]
        )
        let params = try #require(request["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])

        #expect((params["sandboxPolicy"] as? [String: Any])?["type"] as? String == "readOnly")
        #expect(input.count == 2)
        #expect(input[0]["type"] as? String == "text")
        #expect(input[0]["text"] as? String == "look at my screen")
        #expect(input[1]["type"] as? String == "localImage")
        #expect(input[1]["path"] as? String == "/tmp/lorelei-screen.jpg")
    }

    @Test func appServerTurnSteerRequestEncodesActiveTurnPrecondition() throws {
        let request = CodexAppServerProtocol.turnSteerRequest(
            id: 7,
            threadID: "thread-1",
            expectedTurnID: "turn-9",
            prompt: "actually, use the other window"
        )
        let params = try #require(request["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])
        let textInput = try #require(input.first)

        #expect(request["id"] as? Int == 7)
        #expect(request["method"] as? String == "turn/steer")
        #expect(params["threadId"] as? String == "thread-1")
        #expect(params["expectedTurnId"] as? String == "turn-9")
        #expect(textInput["type"] as? String == "text")
        #expect(textInput["text"] as? String == "actually, use the other window")
        #expect((textInput["text_elements"] as? [Any])?.isEmpty == true)
    }

    @Test func appServerThreadStartSendsNoPluginConfig() throws {
        let request = CodexAppServerProtocol.threadStartRequest(id: 2, cwd: "/Users/example")
        let params = try #require(request["params"] as? [String: Any])

        #expect(params["config"] == nil)
    }

    @Test func appServerThreadStartCanRegisterDynamicTools() throws {
        let request = CodexAppServerProtocol.threadStartRequest(
            id: 2,
            cwd: "/Users/example",
            dynamicTools: [
                CodexAppServerDynamicToolSpec(
                    name: "foreground_app",
                    namespace: "lorelei",
                    description: "Bring an app onscreen.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "bundleIdentifier": .object([
                                "type": .string("string")
                            ])
                        ])
                    ])
                )
            ]
        )
        let params = try #require(request["params"] as? [String: Any])
        let dynamicTools = try #require(params["dynamicTools"] as? [[String: Any]])
        let tool = try #require(dynamicTools.first)
        let inputSchema = try #require(tool["inputSchema"] as? [String: Any])

        #expect(tool["name"] as? String == "foreground_app")
        #expect(tool["namespace"] as? String == "lorelei")
        #expect(tool["description"] as? String == "Bring an app onscreen.")
        #expect(inputSchema["type"] as? String == "object")
    }

    @Test func foregroundDynamicToolSpecRegistersLoreleiForegroundApp() throws {
        let spec = CodexAppServerDesktopForegroundTool.spec

        #expect(spec.name == "foreground_app")
        #expect(spec.namespace == "lorelei")
        #expect(spec.description.contains("current macOS Space"))

        guard case .object(let schema) = spec.inputSchema else {
            Issue.record("Expected object input schema.")
            return
        }
        guard case .object(let properties) = schema["properties"] else {
            Issue.record("Expected schema properties.")
            return
        }

        #expect(schema["type"] == .string("object"))
        #expect(properties["appName"] != nil)
        #expect(properties["bundleIdentifier"] != nil)
        #expect(properties["url"] != nil)
        #expect(properties["maxSpaceSwitches"] != nil)
    }

    @Test func foregroundDynamicToolOpensURLActivatesAndReturnsWhenWindowAlreadyOnscreen() async throws {
        let recorder = ForegroundEnvironmentRecorder(onscreenResults: [true])
        let tool = CodexAppServerDesktopForegroundTool(environment: recorder.environment())

        let result = await tool.handle(foregroundToolRequest(arguments: .object([
            "appName": .string("Google Chrome"),
            "bundleIdentifier": .string("com.google.Chrome"),
            "url": .string("https://chatgpt.com")
        ])))

        #expect(result.success)
        #expect(textContent(result)?.contains("Google Chrome") == true)
        #expect(textContent(result)?.contains("onscreen") == true)
        #expect(recorder.events == [
            "open:https://chatgpt.com:Google Chrome:com.google.Chrome",
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome"
        ])
    }

    @Test func foregroundDynamicToolCyclesSpacesUntilTargetWindowIsOnscreen() async throws {
        let recorder = ForegroundEnvironmentRecorder(onscreenResults: [false, false, true])
        let tool = CodexAppServerDesktopForegroundTool(environment: recorder.environment())

        let result = await tool.handle(foregroundToolRequest(arguments: .object([
            "appName": .string("Google Chrome"),
            "bundleIdentifier": .string("com.google.Chrome"),
            "maxSpaceSwitches": .number(3)
        ])))

        #expect(result.success)
        #expect(recorder.spaceDirections == [.right, .right])
        #expect(recorder.events == [
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome",
            "switch:right",
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome",
            "switch:right",
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome"
        ])
    }

    @Test func foregroundActivationPlanYieldsThenActivatesThenOpensBundleFallbackForRunningApps() throws {
        #expect(LiveDesktopForegrounding.activationPlan(isAppAlreadyRunning: true) == [
            .yieldActivationToRunningApplication,
            .activateRunningApplication,
            .openApplicationActivatingBundleURL,
            .reResolveRunningApplicationAfterLaunch,
            .waitUntilFinishedLaunching,
            .setAccessibilityFrontmost,
            .retryActivationUntilFrontmostApplication
        ])
    }

    @Test func foregroundActivationPlanOpensApplicationForNotRunningApps() throws {
        #expect(LiveDesktopForegrounding.activationPlan(isAppAlreadyRunning: false) == [
            .openApplicationActivatingBundleURL,
            .reResolveRunningApplicationAfterLaunch,
            .waitUntilFinishedLaunching,
            .setAccessibilityFrontmost,
            .retryActivationUntilFrontmostApplication
        ])
    }

    @Test func foregroundActivationPlanWaitsForFinishedLaunchingOnColdLaunch() throws {
        #expect(LiveDesktopForegrounding.shouldWaitForFinishedLaunching(isAppAlreadyRunning: false))
        #expect(!LiveDesktopForegrounding.shouldWaitForFinishedLaunching(isAppAlreadyRunning: true))
    }

    @Test func foregroundDynamicToolReportsMissingTarget() async throws {
        let recorder = ForegroundEnvironmentRecorder(onscreenResults: [])
        let tool = CodexAppServerDesktopForegroundTool(environment: recorder.environment())

        let result = await tool.handle(foregroundToolRequest(arguments: .object([:])))

        #expect(!result.success)
        #expect(textContent(result)?.contains("appName or bundleIdentifier") == true)
        #expect(recorder.events.isEmpty)
    }

    @Test func appServerProtocolParsesThreadStartResponse() throws {
        let line = """
        {"id":1,"result":{"thread":{"id":"thread-1"}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .threadStarted(requestID: 1, threadID: "thread-1"))
    }

    @Test func appServerProtocolParsesAgentMessageDelta() throws {
        let line = """
        {"method":"item/agentMessage/delta","params":{"delta":"Opened TextEdit."}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .agentMessageDelta("Opened TextEdit."))
    }

    @Test func appServerProtocolParsesToolUserInputRequest() throws {
        let line = """
        {"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow Codex to control Google Chrome?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow this action."},{"label":"Decline","description":"Stop this action."}]}]}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .approvalRequest(
            CodexAppServerApprovalRequest(
                requestID: 42,
                kind: .toolUserInput,
                title: "Computer Use",
                detail: "Allow Codex to control Google Chrome?",
                acceptPayload: .toolUserInput(questionID: "approval", answer: "Accept"),
                declinePayload: .toolUserInput(questionID: "approval", answer: "Decline")
            )
        ))
    }

    @Test func appServerProtocolParsesCommandApprovalRequest() throws {
        let line = """
        {"id":43,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-2","reason":"Need to open a local app.","command":"/usr/bin/open -a TextEdit","cwd":"/Users/example"}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .approvalRequest(
            CodexAppServerApprovalRequest(
                requestID: 43,
                kind: .commandExecution,
                title: "Codex command approval",
                detail: "Need to open a local app.\n/usr/bin/open -a TextEdit",
                acceptPayload: .commandDecision("accept"),
                declinePayload: .commandDecision("cancel")
            )
        ))
    }

    @Test func appServerProtocolParsesMcpElicitationRequestAsApproval() throws {
        let line = """
        {"id":0,"method":"mcpServer/elicitation/request","params":{"threadId":"thread-1","turnId":"turn-1","serverName":"example-server","mode":"form","_meta":null,"message":"Allow Codex to inspect Google Chrome?","requestedSchema":{"type":"object","properties":{}}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .approvalRequest(
            CodexAppServerApprovalRequest(
                requestID: 0,
                kind: .mcpElicitation,
                title: "MCP server approval",
                detail: "Allow Codex to inspect Google Chrome?\nServer: example-server",
                acceptPayload: .mcpElicitationAccept,
                declinePayload: .mcpElicitationDecline
            )
        ))
    }

    @Test func appServerProtocolParsesPermissionsApprovalRequest() throws {
        let line = """
        {"id":46,"method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-3","startedAtMs":1779912000000,"cwd":"/Users/example","reason":"Need network access for this desktop action.","permissions":{"network":{"enabled":true},"fileSystem":null}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .approvalRequest(
            CodexAppServerApprovalRequest(
                requestID: 46,
                kind: .permissions,
                title: "Codex permissions approval",
                detail: "Need network access for this desktop action.\nPermissions: network",
                acceptPayload: .permissionsGranted(
                    .object([
                        "network": .object([
                            "enabled": .bool(true)
                        ])
                    ]),
                    scope: "turn"
                ),
                declinePayload: .permissionsDenied
            )
        ))
    }

    @Test func appServerProtocolParsesDynamicToolCallRequest() throws {
        let line = """
        {"id":47,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","namespace":"lorelei","tool":"foreground_app","arguments":{"bundleIdentifier":"com.google.Chrome","url":"https://chatgpt.com"}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .dynamicToolCall(
            CodexAppServerDynamicToolCallRequest(
                requestID: 47,
                callID: "call-1",
                namespace: "lorelei",
                tool: "foreground_app",
                arguments: .object([
                    "bundleIdentifier": .string("com.google.Chrome"),
                    "url": .string("https://chatgpt.com")
                ])
            )
        ))
    }

    @Test func appServerDynamicToolCallResponseUsesContentItems() throws {
        let response = CodexAppServerProtocol.dynamicToolCallResponse(
            id: 47,
            result: CodexAppServerDynamicToolCallResult(
                success: true,
                contentText: "Chrome is onscreen."
            )
        )
        let result = try #require(response["result"] as? [String: Any])
        let contentItems = try #require(result["contentItems"] as? [[String: Any]])
        let firstItem = try #require(contentItems.first)

        #expect(response["id"] as? Int == 47)
        #expect(result["success"] as? Bool == true)
        #expect(firstItem["type"] as? String == "inputText")
        #expect(firstItem["text"] as? String == "Chrome is onscreen.")
    }

    @Test func dynamicToolCallResponseEncodesImageContentItems() throws {
        let response = CodexAppServerProtocol.dynamicToolCallResponse(
            id: 48,
            result: CodexAppServerDynamicToolCallResult(
                success: true,
                contentItems: [
                    .text("done"),
                    .image(dataURL: "data:image/png;base64,AA==")
                ]
            )
        )
        let result = try #require(response["result"] as? [String: Any])
        let contentItems = try #require(result["contentItems"] as? [[String: Any]])

        #expect(contentItems.count == 2)
        #expect(contentItems[0]["type"] as? String == "inputText")
        #expect(contentItems[0]["text"] as? String == "done")
        #expect(contentItems[1]["type"] as? String == "inputImage")
        #expect(contentItems[1]["imageUrl"] as? String == "data:image/png;base64,AA==")
    }

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

    @Test func axSerializerAssignsDepthFirstIDsAndFormatsLines() throws {
        let root = DesktopUINode(
            role: "AXWindow",
            title: "Demo",
            value: nil,
            frame: CGRect(x: 0, y: 25, width: 1024, height: 743),
            isEnabled: true,
            isFocused: false,
            children: [
                DesktopUINode(
                    role: "AXGroup",
                    title: "Toolbar",
                    value: nil,
                    frame: nil,
                    isEnabled: true,
                    isFocused: false,
                    children: [
                        DesktopUINode(
                            role: "AXButton",
                            title: "Save",
                            value: nil,
                            frame: nil,
                            isEnabled: false,
                            isFocused: false,
                            children: []
                        )
                    ]
                ),
                DesktopUINode(
                    role: "AXTextArea",
                    title: nil,
                    value: "Hello",
                    frame: nil,
                    isEnabled: true,
                    isFocused: true,
                    children: []
                )
            ]
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(root, assigningIDsInto: &registry)

        #expect(result.text == """
        [e1] AXWindow "Demo" (0,25 1024x743)
          [e2] AXGroup "Toolbar"
            [e3] AXButton "Save" disabled
          [e4] AXTextArea value="Hello" focused
        """)
        #expect(result.elementCount == 4)
        #expect(registry == ["e1": 0, "e2": 1, "e3": 2, "e4": 3])
    }

    @Test func axSerializerPromotesChildrenOfBareStructuralNodes() throws {
        let root = DesktopUINode(
            role: "AXGroup",
            title: nil,
            value: nil,
            frame: nil,
            isEnabled: true,
            isFocused: false,
            children: [
                DesktopUINode(
                    role: "AXButton",
                    title: "First",
                    value: nil,
                    frame: nil,
                    isEnabled: true,
                    isFocused: false,
                    children: []
                ),
                DesktopUINode(
                    role: "AXSplitGroup",
                    title: nil,
                    value: nil,
                    frame: nil,
                    isEnabled: true,
                    isFocused: false,
                    children: [
                        DesktopUINode(
                            role: "AXButton",
                            title: "Second",
                            value: nil,
                            frame: nil,
                            isEnabled: true,
                            isFocused: false,
                            children: []
                        )
                    ]
                )
            ]
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(root, assigningIDsInto: &registry)

        #expect(result.text == """
        [e1] AXButton "First"
        [e2] AXButton "Second"
        """)
        #expect(result.elementCount == 2)
        #expect(registry == ["e1": 0, "e2": 1])
    }

    @Test func axSerializerIncludesHintsAndRoleDescriptionsWhenTheyAddInformation() throws {
        let root = DesktopUINode(
            role: "AXWindow",
            title: "Notes",
            value: nil,
            frame: nil,
            isEnabled: true,
            isFocused: false,
            children: [
                DesktopUINode(
                    role: "AXButton",
                    title: "New Folder",
                    roleDescription: "toolbar button",
                    value: nil,
                    hint: "Create a new folder",
                    frame: nil,
                    isEnabled: true,
                    isFocused: false,
                    children: []
                ),
                DesktopUINode(
                    role: "AXButton",
                    title: "New Note",
                    roleDescription: "New Note",
                    value: nil,
                    hint: "New Note",
                    frame: nil,
                    isEnabled: true,
                    isFocused: false,
                    children: []
                )
            ]
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(root, assigningIDsInto: &registry)

        #expect(result.text == """
        [e1] AXWindow "Notes"
          [e2] AXButton "New Folder" roleDescription="toolbar button" hint="Create a new folder"
          [e3] AXButton "New Note"
        """)
    }

    @Test func axSerializerPrioritizesMenuBarAndFocusedWindowChromeBeforeLargeLists() throws {
        let rows = (0..<26).map { index in
            DesktopUINode(
                role: "AXRow",
                title: "Note \(index)",
                value: nil,
                frame: nil,
                isEnabled: true,
                isFocused: false,
                supportedActions: [.press, .open, .showMenu],
                children: []
            )
        }
        let root = DesktopUINode(
            role: "AXApplication",
            title: "Notes",
            value: nil,
            frame: nil,
            isEnabled: true,
            isFocused: false,
            children: [
                DesktopUINode(
                    role: "AXWindow",
                    title: "Notes",
                    value: nil,
                    frame: nil,
                    isEnabled: true,
                    isFocused: true,
                    children: [
                        DesktopUINode(
                            role: "AXList",
                            title: "Notes list",
                            value: nil,
                            frame: nil,
                            isEnabled: true,
                            isFocused: false,
                            children: rows
                        ),
                        DesktopUINode(
                            role: "AXToolbar",
                            title: nil,
                            value: nil,
                            frame: nil,
                            isEnabled: true,
                            isFocused: false,
                            children: [
                                DesktopUINode(
                                    role: "AXButton",
                                    title: "New Note",
                                    value: nil,
                                    frame: nil,
                                    isEnabled: true,
                                    isFocused: false,
                                    children: []
                                )
                            ]
                        )
                    ]
                ),
                DesktopUINode(
                    role: "AXMenuBar",
                    title: nil,
                    value: nil,
                    frame: nil,
                    isEnabled: true,
                    isFocused: false,
                    children: [
                        DesktopUINode(
                            role: "AXMenuBarItem",
                            title: "File",
                            value: nil,
                            frame: nil,
                            isEnabled: true,
                            isFocused: false,
                            children: []
                        )
                    ]
                )
            ]
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(root, assigningIDsInto: &registry)
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.prefix(9) == [
            "[e1] AXApplication \"Notes\"",
            "  [e2] AXMenuBar",
            "    [e3] AXMenuBarItem \"File\"",
            "  [e4] AXWindow \"Notes\" focused",
            "    [e5] AXToolbar",
            "      [e6] AXButton \"New Note\"",
            "    [e7] AXList \"Notes list\"",
            "      [e8] AXRow \"Note 0\" actions=\"open,showMenu\"",
            "      [e9] AXRow \"Note 1\" actions=\"open,showMenu\""
        ])
        #expect(lines.contains("      … (+2 more rows)"))
        #expect(result.elementCount == 31)
        #expect(registry["e31"] == 30)
        #expect(registry["e32"] == nil)
    }

    @Test func axSerializerTruncatesLongValuesAndElementCount() throws {
        let longValue = String(repeating: "a", count: 90)
        let children = (0..<401).map { index in
            DesktopUINode(
                role: "AXButton",
                title: "Button \(index)",
                value: nil,
                frame: nil,
                isEnabled: true,
                isFocused: false,
                children: []
            )
        }
        let root = DesktopUINode(
            role: "AXWindow",
            title: "Demo",
            value: longValue,
            frame: CGRect(x: 10.4, y: 20.6, width: 300.2, height: 200.8),
            isEnabled: true,
            isFocused: false,
            children: children
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(root, assigningIDsInto: &registry)
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let expectedValue = String(repeating: "a", count: 79) + "…"

        #expect(lines.first == "[e1] AXWindow \"Demo\" value=\"\(expectedValue)\" (10,21 300x201)")
        #expect(lines.last == "… truncated (2 elements omitted)")
        #expect(result.elementCount == 400)
        #expect(registry.count == 400)
        #expect(registry["e1"] == 0)
        #expect(registry["e400"] == 399)
        #expect(registry["e401"] == nil)
    }

    @Test func axSerializerPrefixesFocusedElementOutsideNormalBudget() throws {
        let children = (0..<400).map { index in
            DesktopUINode(
                role: "AXButton",
                title: "Button \(index)",
                value: nil,
                frame: nil,
                isEnabled: true,
                isFocused: false,
                children: []
            )
        }
        let root = DesktopUINode(
            role: "AXWindow",
            title: "Demo",
            value: nil,
            frame: nil,
            isEnabled: true,
            isFocused: false,
            children: children
        )
        let focusedNode = DesktopUINode(
            role: "AXTextArea",
            title: nil,
            value: "Draft body",
            frame: nil,
            isEnabled: true,
            isFocused: true,
            children: []
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(
            root,
            assigningIDsInto: &registry,
            focusedLine: (node: focusedNode, elementID: "e401", registryIndex: 400)
        )
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.first == "[focused] [e401] AXTextArea value=\"Draft body\" focused")
        #expect(lines[1] == "[e1] AXWindow \"Demo\"")
        #expect(result.elementCount == 401)
        #expect(registry["e401"] == 400)
    }

    @Test func axSerializerKeepsFocusedLineAndTreeLineOnSameElementID() throws {
        let focusedNode = DesktopUINode(
            role: "AXTextArea",
            title: nil,
            value: "Draft body",
            frame: nil,
            isEnabled: true,
            isFocused: true,
            children: []
        )
        let root = DesktopUINode(
            role: "AXWindow",
            title: "Demo",
            value: nil,
            frame: nil,
            isEnabled: true,
            isFocused: false,
            children: [focusedNode]
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(
            root,
            assigningIDsInto: &registry,
            focusedLine: (node: focusedNode, elementID: "e2", registryIndex: 1)
        )
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines == [
            "[focused] [e2] AXTextArea value=\"Draft body\" focused",
            "[e1] AXWindow \"Demo\"",
            "  [e2] AXTextArea value=\"Draft body\" focused"
        ])
        #expect(result.elementCount == 2)
        #expect(registry == ["e1": 0, "e2": 1])
    }

    @Test func axSerializerBudgetsMenuChildrenAndPreservesWindowContent() throws {
        let menus = (0..<6).map { menuIndex in
            DesktopUINode(
                role: "AXMenuBarItem",
                title: "Menu \(menuIndex)",
                value: nil,
                frame: nil,
                isEnabled: true,
                isFocused: false,
                children: [
                    DesktopUINode(
                        role: "AXMenu",
                        title: nil,
                        value: nil,
                        frame: nil,
                        isEnabled: true,
                        isFocused: false,
                        children: (0..<30).map { itemIndex in
                            DesktopUINode(
                                role: "AXMenuItem",
                                title: "Item \(menuIndex)-\(itemIndex)",
                                value: nil,
                                frame: nil,
                                isEnabled: true,
                                isFocused: false,
                                children: []
                            )
                        }
                    )
                ]
            )
        }
        let root = DesktopUINode(
            role: "AXApplication",
            title: "Notes",
            value: nil,
            frame: nil,
            isEnabled: true,
            isFocused: false,
            children: [
                DesktopUINode(
                    role: "AXMenuBar",
                    title: nil,
                    value: nil,
                    frame: nil,
                    isEnabled: true,
                    isFocused: false,
                    children: menus
                ),
                DesktopUINode(
                    role: "AXWindow",
                    title: "Notes",
                    value: nil,
                    frame: nil,
                    isEnabled: true,
                    isFocused: true,
                    children: [
                        DesktopUINode(
                            role: "AXTextArea",
                            title: nil,
                            value: "Window text survives",
                            frame: nil,
                            isEnabled: true,
                            isFocused: true,
                            children: []
                        )
                    ]
                )
            ]
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(root, assigningIDsInto: &registry)
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.contains { $0.contains("… (+6 more rows)") })
        #expect(result.text.contains("AXWindow \"Notes\" focused"))
        #expect(result.text.contains("AXTextArea value=\"Window text survives\" focused"))
        #expect(!result.text.contains("Item 0-24"))
        #expect(result.elementCount < 170)
    }

    @Test func axExecutorRejectsActionsWithUnknownElementID() async throws {
        let executor = AXDesktopActionExecutor(hasAccessibilityPermission: { true })

        let outcome = await executor.perform(.press, elementID: "e9")

        #expect(!outcome.success)
        #expect(outcome.message == DesktopActionError.staleElementID("e9").toolMessage)
    }

    @Test func axExecutorReportsMissingAccessibilityPermission() async throws {
        let executor = AXDesktopActionExecutor(hasAccessibilityPermission: { false })

        let result = await executor.snapshot(appName: nil)

        #expect(result == .failure(.accessibilityPermissionMissing))
    }

    @Test func appServerExecutorDefaultTurnTimeoutIsFiveMinutes() async throws {
        let executor = CodexAppServerExecutor(
            makeTransport: { FakeCodexAppServerTransport(lines: []) },
            approvalHandler: { _ in .accept }
        )

        #expect(executor.defaultedTurnTimeoutSecondsForTesting == 300)
    }

    @Test func appServerExecutorAnswersMcpElicitationApprovalWithZeroID() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":0,"method":"mcpServer/elicitation/request","params":{"threadId":"thread-1","turnId":"turn-1","serverName":"example-server","mode":"form","_meta":null,"message":"Allow Codex to use Google Chrome?","requestedSchema":{"type":"object","properties":{}}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Approved and done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .accept }
        )

        let result = await executor.runDesktopAction(prompt: "inspect Chrome", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(result.summary == "Approved and done")
        #expect(await transport.sentLines.contains { line in
            line.contains(#""id":0"#)
                && line.contains(#""action":"accept""#)
                && line.contains(#""content":{}"#)
        })
    }

    @Test func appServerExecutorAnswersPermissionsApproval() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":46,"method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-3","startedAtMs":1779912000000,"cwd":"/Users/example","reason":"Need network access.","permissions":{"network":{"enabled":true},"fileSystem":null}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Approved permissions and done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .accept }
        )

        let result = await executor.runDesktopAction(prompt: "open a URL", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(result.summary == "Approved permissions and done")

        let responseLine = try #require(await transport.sentLines.first { line in
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return root["id"] as? Int == 46
        })
        let response = try #require(try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any])
        let responseResult = try #require(response["result"] as? [String: Any])
        let permissions = try #require(responseResult["permissions"] as? [String: Any])
        let network = try #require(permissions["network"] as? [String: Any])

        #expect(network["enabled"] as? Bool == true)
        #expect(permissions["fileSystem"] == nil)
        #expect(responseResult["scope"] as? String == "turn")
    }

    @Test func appServerExecutorReportsFailedMcpToolCallEvenWhenTurnCompletes() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"item-1","type":"mcpToolCall","status":"failed","server":"example-server","tool":"get_app_state","result":{"content":[{"type":"text","text":"Example server error"}],"isError":true}}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"I could not read the Google Chrome window."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .accept }
        )

        let result = await executor.runDesktopAction(prompt: "inspect Chrome", cwd: "/Users/example")

        #expect(result.status == .failed)
        #expect(result.summary == "I could not read the Google Chrome window.")
    }

    @Test func appServerProtocolParsesGeneratedTurnCompletedShape() throws {
        let line = """
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":"all","status":"failed","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .turnCompleted(status: "failed"))
    }

    @Test func appServerProtocolParsesWaitingOnApprovalStatus() throws {
        let line = """
        {"method":"thread/status/changed","params":{"threadId":"thread-1","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .threadWaitingOnApproval(true))
    }

    @Test func appServerProtocolFailsFastForUnsupportedServerRequests() throws {
        let line = """
        {"id":45,"method":"item/unknown/request","params":{"threadId":"thread-1","turnId":"turn-1"}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .unsupportedServerRequest(requestID: 45, method: "item/unknown/request"))
    }

    @Test func appServerExecutorStartsThreadAndTurn() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "open TextEdit", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(result.summary == "Done")
        #expect(await transport.sentMethods == ["initialize", "initialized", "thread/start", "turn/start"])
    }

    @Test func appServerDesktopActionTurnStartUsesReadOnlySandbox() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "open TextEdit", cwd: "/Users/example")
        let sentMessages = try await transport.sentJSONMessages()
        let turnStart = try #require(sentMessages.first { $0["method"] as? String == "turn/start" })
        let params = try #require(turnStart["params"] as? [String: Any])
        let sandboxPolicy = try #require(params["sandboxPolicy"] as? [String: Any])

        #expect(result.status == .succeeded)
        #expect(result.summary == "Done")
        #expect(sandboxPolicy["type"] as? String == "readOnly")
    }

    @Test func appServerSessionReusesTransportAcrossTurns() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"First"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Second"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let factoryCallCount = AsyncCounter()
        let executor = CodexAppServerExecutor(
            makeTransport: {
                await factoryCallCount.increment()
                return transport
            },
            approvalHandler: { _ in .cancel }
        )

        let first = await executor.runDesktopAction(prompt: "first", cwd: "/Users/example")
        let didTerminateAfterFirstTurn = await transport.didTerminate
        let second = await executor.runDesktopAction(prompt: "second", cwd: "/Users/example")

        #expect(first.status == .succeeded)
        #expect(first.summary == "First")
        #expect(second.status == .succeeded)
        #expect(second.summary == "Second")
        #expect(await factoryCallCount.value == 1)
        #expect(!didTerminateAfterFirstTurn)
        let sentMessages = try await transport.sentJSONMessages()
        let turnStarts = sentMessages.filter { $0["method"] as? String == "turn/start" }
        #expect(turnStarts.map { $0["id"] as? Int } == [3, 4])
    }

    @Test func appServerSessionRespawnsWhenCwdChanges() async throws {
        let firstTransport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"First"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let secondTransport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-2"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Second"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let factory = AppServerTransportFactoryRecorder(transports: [firstTransport, secondTransport])
        let executor = CodexAppServerExecutor(
            makeTransport: { try await factory.next() },
            approvalHandler: { _ in .cancel }
        )

        _ = await executor.runDesktopAction(prompt: "first", cwd: "/Users/example/one")
        _ = await executor.runDesktopAction(prompt: "second", cwd: "/Users/example/two")

        #expect(await factory.callCount == 2)
        #expect(await firstTransport.didTerminate)
        let sentMessages = try await secondTransport.sentJSONMessages()
        let threadStart = try #require(sentMessages.first { $0["method"] as? String == "thread/start" })
        let params = try #require(threadStart["params"] as? [String: Any])
        #expect(params["cwd"] as? String == "/Users/example/two")
    }

    @Test func appServerSessionRetriesOnceOnDeadTransport() async throws {
        let deadTransport = ThrowingSendCodexAppServerTransport()
        let healthyTransport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-2"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Recovered"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let factory = AppServerTransportFactoryRecorder(transports: [deadTransport, healthyTransport])
        let executor = CodexAppServerExecutor(
            makeTransport: { try await factory.next() },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "recover", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(result.summary == "Recovered")
        #expect(await factory.callCount == 2)
        #expect(await deadTransport.didTerminate)
    }

    @Test func appServerStopInvalidatesSession() async throws {
        let firstTransport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        ])
        let secondTransport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-2"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Fresh"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let factory = AppServerTransportFactoryRecorder(transports: [firstTransport, secondTransport])
        let executor = CodexAppServerExecutor(
            // Generous, not knife-edge: the timer must lose the race against
            // consuming the scripted session/turn lines, or the turn never
            // starts and the timeout-shape contract cannot hold. 1.0s still
            // flaked on cold first runs of the full suite, so this uses 2.0s.
            turnTimeoutSeconds: 2.0,
            makeTransport: { try await factory.next() },
            approvalHandler: { _ in .cancel }
        )

        let stopped = await executor.runDesktopAction(prompt: "stop", cwd: "/Users/example")
        let fresh = await executor.runDesktopAction(prompt: "fresh", cwd: "/Users/example")

        #expect(stopped.status == .failed)
        #expect(stopped.summary.contains("Codex App Server command timed out."))
        #expect(fresh.status == .succeeded)
        #expect(fresh.summary == "Fresh")
        #expect(await factory.callCount == 2)
    }

    @Test func appServerExecutorAnswersToolUserInputApproval() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":44,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow control?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow."},{"label":"Decline","description":"Stop."}]}]}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Approved and done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .accept }
        )

        let result = await executor.runDesktopAction(prompt: "click submit", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(result.summary == "Approved and done")
        #expect(await transport.sentLines.contains { $0.contains(#""id":44"#) && $0.contains(#""Accept"#) })
    }

    @Test func appServerExecutorTimesOutSilentServer() async throws {
        let transport = HangingCodexAppServerTransport()
        let executor = CodexAppServerExecutor(
            // Generous, not knife-edge: the timer must lose the race against
            // consuming the scripted session/turn lines, or the turn never
            // starts and the timeout-shape contract cannot hold. 1.0s still
            // flaked on cold first runs of the full suite, so this uses 2.0s.
            turnTimeoutSeconds: 2.0,
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "open TextEdit", cwd: "/Users/example")

        #expect(result.summary.contains("Codex App Server command timed out."))
        #expect(result.status == .failed)
        #expect(await transport.didTerminate)
    }

    @Test func appServerExecutorIncludesProtocolTraceWhenTimeoutHappensAfterThreadStart() async throws {
        let transport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        ])
        let executor = CodexAppServerExecutor(
            // Generous, not knife-edge: the timer must lose the race against
            // consuming the scripted session/turn lines, or the turn never
            // starts and the timeout-shape contract cannot hold. 1.0s still
            // flaked on cold first runs of the full suite, so this uses 2.0s.
            turnTimeoutSeconds: 2.0,
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "open Chrome", cwd: "/Users/example")

        #expect(result.status == .failed)
        #expect(result.summary.contains("Codex App Server command timed out."))
        #expect(result.summary.contains("Trace:"))
        #expect(result.summary.contains("outbound initialize#1"))
        #expect(result.summary.contains("inbound threadStarted#2:thread-1"))
        #expect(result.summary.contains("outbound turn/start#3"))
    }

    @Test func appServerExecutorReportsTimeoutWhenTransportReadThrowsAfterTermination() async throws {
        let transport = ThrowingAfterTerminateCodexAppServerTransport()
        let executor = CodexAppServerExecutor(
            // Generous, not knife-edge: the timer must lose the race against
            // consuming the scripted session/turn lines, or the turn never
            // starts and the timeout-shape contract cannot hold. 1.0s still
            // flaked on cold first runs of the full suite, so this uses 2.0s.
            turnTimeoutSeconds: 2.0,
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "open TextEdit", cwd: "/Users/example")

        #expect(result.summary.contains("Codex App Server command timed out."))
        #expect(result.status == .failed)
        #expect(await transport.didTerminate)
    }

    @Test func appServerExecutorReportsUndeliveredApprovalRequestOnTimeout() async throws {
        let transport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"thread/status/changed","params":{"threadId":"thread-1","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}"#
        ])
        // Generous, not knife-edge: the scripted lines - including the
        // waitingOnApproval status the hint depends on - must be consumed
        // before the timer fires now that the timeout also covers session
        // establishment. This test needs THREE lines consumed pre-timeout,
        // making it the most schedule-sensitive of the timeout family: it
        // flaked at 1.0s and again at 2.0s under parallel-suite load, so it
        // alone uses 3.0s.
        let executor = CodexAppServerExecutor(
            turnTimeoutSeconds: 3.0,
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "inspect TextEdit", cwd: "/Users/example")

        #expect(result.summary.contains("Codex App Server is waiting for approval, but no approval request was delivered."))
        #expect(result.status == .failed)
        #expect(await transport.didTerminate)
    }

    @Test func appServerExecutorTimeoutInterruptsBeforeTerminating() async throws {
        let completingTransport = InterruptCompletingCodexAppServerTransport(
            initialLines: [
                #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
                #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
                #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#
            ],
            interruptCompletionLines: [
                #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"interrupted"}}}"#
            ]
        )
        let completingExecutor = CodexAppServerExecutor(
            // Generous, not knife-edge: the timer must lose the race against
            // consuming the scripted session/turn lines under parallel-suite
            // load. 1.0s still flaked on cold first runs of the full suite,
            // so this uses 2.0s.
            turnTimeoutSeconds: 2.0,
            timeoutInterruptGraceSeconds: 1.0,
            makeTransport: { completingTransport },
            approvalHandler: { _ in .cancel }
        )

        let completingResult = await completingExecutor.runDesktopAction(prompt: "open TextEdit", cwd: "/Users/example")
        let completingMessages = try await completingTransport.sentJSONMessages()
        let interrupt = try #require(completingMessages.first { $0["method"] as? String == "turn/interrupt" })
        let interruptParams = try #require(interrupt["params"] as? [String: Any])

        #expect(completingResult.status == .failed)
        #expect(completingResult.summary.contains("Codex App Server command timed out."))
        #expect(interruptParams["threadId"] as? String == "thread-1")
        #expect(interruptParams["turnId"] as? String == "turn-9")
        #expect(!(await completingTransport.didTerminate))

        let silentTransport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#
        ])
        let silentExecutor = CodexAppServerExecutor(
            // Generous, not knife-edge: the timer must lose the race against
            // consuming the scripted session/turn lines under parallel-suite
            // load. 1.0s still flaked on cold first runs of the full suite,
            // so this uses 2.0s.
            turnTimeoutSeconds: 2.0,
            timeoutInterruptGraceSeconds: 0.05,
            makeTransport: { silentTransport },
            approvalHandler: { _ in .cancel }
        )

        let silentResult = await silentExecutor.runDesktopAction(prompt: "open TextEdit", cwd: "/Users/example")
        let silentMessages = try await silentTransport.sentJSONMessages()

        #expect(silentResult.status == .failed)
        #expect(silentResult.summary.contains("Codex App Server command timed out."))
        #expect(silentMessages.contains { $0["method"] as? String == "turn/interrupt" })
        #expect(await silentTransport.didTerminate)
    }

    @Test func appServerExecutorRegistersAndAnswersDynamicToolCalls() async throws {
        let dynamicTool = CodexAppServerDynamicToolSpec(
            name: "foreground_app",
            namespace: "lorelei",
            description: "Bring an app onscreen.",
            inputSchema: .object(["type": .string("object")])
        )
        let dynamicToolRequestRecorder = StringRecorder()
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":47,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","namespace":"lorelei","tool":"foreground_app","arguments":{"bundleIdentifier":"com.google.Chrome"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Foregrounded and done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            dynamicToolSpecsResolver: { [dynamicTool] },
            dynamicToolHandler: { request in
                dynamicToolRequestRecorder.record(request.tool)
                return CodexAppServerDynamicToolCallResult(
                    success: true,
                    contentText: "Google Chrome is onscreen."
                )
            },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "foreground Chrome", cwd: "/Users/example")

        #expect(result.summary == "Foregrounded and done")
        #expect(dynamicToolRequestRecorder.values == ["foreground_app"])
        let sentMessages = try await transport.sentLines.map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let threadStart = try #require(sentMessages.first { $0["method"] as? String == "thread/start" })
        let threadStartParams = try #require(threadStart["params"] as? [String: Any])
        let dynamicTools = try #require(threadStartParams["dynamicTools"] as? [[String: Any]])
        let firstDynamicTool = try #require(dynamicTools.first)
        #expect(firstDynamicTool["name"] as? String == "foreground_app")

        let dynamicToolResponse = try #require(sentMessages.first { $0["id"] as? Int == 47 })
        let responseResult = try #require(dynamicToolResponse["result"] as? [String: Any])
        #expect(responseResult["success"] as? Bool == true)
        #expect((responseResult["contentItems"] as? [[String: Any]])?.first?["text"] as? String == "Google Chrome is onscreen.")
    }

    @Test func appServerExecutorRecordsProtocolAndDynamicToolTraceEvents() async throws {
        let dynamicTool = CodexAppServerDynamicToolSpec(
            name: "foreground_app",
            namespace: "lorelei",
            description: "Bring an app onscreen.",
            inputSchema: .object(["type": .string("object")])
        )
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":47,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","namespace":"lorelei","tool":"foreground_app","arguments":{"bundleIdentifier":"com.google.Chrome"}}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let recorder = AppServerTraceRecorder()
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            dynamicToolSpecsResolver: { [dynamicTool] },
            dynamicToolHandler: { _ in
                CodexAppServerDynamicToolCallResult(
                    success: true,
                    contentText: "Google Chrome is onscreen."
                )
            },
            traceHandler: { event in
                recorder.record(event)
            },
            approvalHandler: { _ in .cancel }
        )

        _ = await executor.runDesktopAction(prompt: "foreground Chrome", cwd: "/Users/example")

        let eventLines = Set(recorder.eventLines)
        #expect(eventLines.contains("outbound initialize#1"))
        #expect(eventLines.contains("inbound response#1"))
        #expect(eventLines.contains("inbound dynamicToolCall#47:lorelei.foreground_app"))
        #expect(eventLines.contains("dynamicToolStarted 47:lorelei.foreground_app"))
        #expect(eventLines.contains("dynamicToolCompleted 47:lorelei.foreground_app:success=true"))
        #expect(eventLines.contains("outbound response#47"))
    }

    @Test func executorReportsProgressForDeltasAndToolCalls() async throws {
        let dynamicTool = CodexAppServerDynamicToolSpec(
            name: "desktop_snapshot",
            namespace: "lorelei",
            description: "Read the desktop.",
            inputSchema: .object(["type": .string("object")])
        )
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"id":47,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","namespace":"lorelei","tool":"desktop_snapshot","arguments":{}}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let recorder = AppServerProgressRecorder()
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            dynamicToolSpecsResolver: { [dynamicTool] },
            dynamicToolHandler: { _ in
                CodexAppServerDynamicToolCallResult(success: true, contentText: "snapshot")
            },
            progressHandler: { progress in
                recorder.record(progress)
            },
            approvalHandler: { _ in .cancel }
        )

        _ = await executor.runDesktopAction(prompt: "inspect desktop", cwd: "/Users/example")

        #expect(recorder.progress == [
            .agentMessageDelta("Hel"),
            .agentMessageDelta("lo"),
            .toolCallStarted(name: "lorelei.desktop_snapshot"),
            .toolCallCompleted(name: "lorelei.desktop_snapshot", success: true),
            .turnEnded
        ])
    }

    @Test func appServerExecutorReportsTurnStartedAndEnded() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let recorder = AppServerProgressRecorder()
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            progressHandler: { progress in
                recorder.record(progress)
            },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "inspect desktop", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(recorder.progress == [
            .turnStarted(threadID: "thread-1", turnID: "turn-9"),
            .agentMessageDelta("Hel"),
            .agentMessageDelta("lo"),
            .turnEnded
        ])
    }

    @Test func companionManagerTracksRunStatusThroughVoiceTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerRunStatusVoiceTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerRunStatusVoiceTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        // Record every transition instead of polling: the scripted turn can
        // finish faster than any polling interval, so transient states like
        // .working would otherwise be missed nondeterministically.
        let recorder = RunStatusRecorder()
        let statusCancellable = manager.$runStatus.sink { recorder.record($0) }
        defer { statusCancellable.cancel() }

        manager.simulateShortcutTransitionForTesting(.pressed)
        #expect(manager.runStatus == .listening)

        manager.simulateShortcutTransitionForTesting(.released)
        #expect(manager.runStatus == .transcribing)

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<200 {
            if recorder.statuses.contains(.finished(success: true)) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let statuses = recorder.statuses
        #expect(statuses.contains(.finished(success: true)))
        #expect(isOrderedSubsequence(
            [.listening, .transcribing, .working("Thinking…"), .finished(success: true)],
            of: statuses
        ))
        #expect(manager.streamText == "Hello")
    }

    @Test func companionManagerReturnsToIdleWhenTranscribeProducesNoTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerTranscribingWatchdogTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerTranscribingWatchdogTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            transcribingWatchdogDelay: .milliseconds(300)
        )

        manager.simulateShortcutTransitionForTesting(.pressed)
        manager.simulateShortcutTransitionForTesting(.released)
        #expect(manager.runStatus == .transcribing)

        // No transcript ever arrives (silent hold / no-audio device); the
        // watchdog must return the status to idle instead of sticking.
        for _ in 0..<150 {
            if manager.runStatus == .idle { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(manager.runStatus == .idle)
    }

    @Test func companionManagerPlaysCuesThroughVoiceTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerAudioVoiceTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerAudioVoiceTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.simulateShortcutTransitionForTesting(.pressed)
        manager.simulateShortcutTransitionForTesting(.released)
        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<200 {
            if audioFeedback.events.contains(where: { $0.cue == .runSucceeded }) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(audioFeedback.events.map(\.cue) == [.listeningStarted, .listeningEnded, .runSucceeded])
        #expect(audioFeedback.events.last?.spokenSummary == "Hello")
    }

    @Test func companionManagerSteersUtteranceIntoRunningTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerSteerRunningTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerSteerRunningTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Working"}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.streamText == "Working" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .working("Thinking…"))
        #expect(manager.streamText == "Working")

        manager.handleFinalTranscriptForTesting("actually the other window")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.contains(where: { $0["method"] as? String == "turn/steer" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        let steer = try #require(sentMessages.first { $0["method"] as? String == "turn/steer" })
        let steerParams = try #require(steer["params"] as? [String: Any])
        let steerInput = try #require(steerParams["input"] as? [[String: Any]])

        #expect(steerParams["threadId"] as? String == "thread-1")
        #expect(steerParams["expectedTurnId"] as? String == "turn-9")
        #expect(steerInput.first?["text"] as? String == "actually the other window")
        #expect(sentMessages.filter { $0["method"] as? String == "turn/start" }.count == 1)
        #expect(manager.runStatus == .working("Thinking…"))
        #expect(manager.streamText == "Working")
        #expect(audioFeedback.events.isEmpty)
    }

    @Test func companionManagerLogsSteeredUtteranceIntoConversation() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerConversationLogSteerTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerConversationLogSteerTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Working"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.streamText == "Working" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.conversationLog.map(\.role) == [
            ConversationEntry.Role.user,
            ConversationEntry.Role.assistant
        ])
        #expect(manager.conversationLog.map(\.text) == [
            "use computer use to inspect TextEdit",
            "Working"
        ])

        manager.handleFinalTranscriptForTesting("actually the other window")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.contains(where: { $0["method"] as? String == "turn/steer" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.conversationLog.map(\.role) == [
            ConversationEntry.Role.user,
            ConversationEntry.Role.assistant,
            ConversationEntry.Role.user
        ])
        #expect(manager.conversationLog.map(\.text) == [
            "use computer use to inspect TextEdit",
            "Working",
            "↪ actually the other window"
        ])
        #expect(manager.conversationLog.filter { $0.role == .assistant }.count == 1)
    }

    @Test func companionManagerStartsNewTurnWhenIdle() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerIdleStartsNewTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerIdleStartsNewTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"First"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-10","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Second"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.runStatus == .finished(success: true) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.runStatus == .finished(success: true))

        manager.handleFinalTranscriptForTesting("use computer use to inspect Safari")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.filter({ $0["method"] as? String == "turn/start" }).count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        #expect(sentMessages.filter { $0["method"] as? String == "turn/start" }.count == 2)
        #expect(!sentMessages.contains { $0["method"] as? String == "turn/steer" })
    }

    @Test func companionManagerRunsReadOnlyUtteranceOnSharedThread() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerReadOnlySharedThreadTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerReadOnlySharedThreadTests")
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = directoryURL.path
        let factoryCallCount = AsyncCounter()
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Opened TextEdit."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-10","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"I opened TextEdit."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: {
                await factoryCallCount.increment()
                return transport
            },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to open TextEdit")
        for _ in 0..<40 {
            if manager.runStatus == .finished(success: true) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        manager.handleFinalTranscriptForTesting("what did you just do")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.filter({ $0["method"] as? String == "turn/start" }).count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        let turnStarts = sentMessages.filter { $0["method"] as? String == "turn/start" }
        let secondParams = try #require(turnStarts.last?["params"] as? [String: Any])
        let secondInput = try #require(secondParams["input"] as? [[String: Any]])

        #expect(await factoryCallCount.value == 1)
        #expect(turnStarts.count == 2)
        #expect(secondParams["threadId"] as? String == "thread-1")
        #expect((secondParams["sandboxPolicy"] as? [String: Any])?["type"] as? String == "readOnly")
        #expect(secondInput.first?["text"] as? String == "what did you just do")
    }

    @Test func companionManagerRunsWorkspaceWriteOnSharedThread() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerWorkspaceWriteSharedThreadTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerWorkspaceWriteSharedThreadTests")
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = directoryURL.path
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Opened TextEdit."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-10","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Fixed the test."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let factoryCallCount = AsyncCounter()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: {
                await factoryCallCount.increment()
                return transport
            },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to open TextEdit")
        for _ in 0..<40 {
            if manager.runStatus == .finished(success: true) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        manager.handleFinalTranscriptForTesting("fix the failing test")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.filter({ $0["method"] as? String == "turn/start" }).count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        let turnStarts = sentMessages.filter { $0["method"] as? String == "turn/start" }
        let secondParams = try #require(turnStarts.last?["params"] as? [String: Any])
        let secondInput = try #require(secondParams["input"] as? [[String: Any]])

        #expect(await factoryCallCount.value == 1)
        #expect(turnStarts.count == 2)
        #expect(secondParams["threadId"] as? String == "thread-1")
        #expect((secondParams["sandboxPolicy"] as? [String: Any])?["type"] as? String == "workspaceWrite")
        #expect(secondInput.first?["text"] as? String == CodexPromptBuilder.workspaceWritePrompt(for: "fix the failing test"))
    }

    @Test func companionManagerStopKeepsSessionForNextTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerStopKeepsSessionTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerStopKeepsSessionTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let factoryCallCount = AsyncCounter()
        let transport = InterruptCompletingCodexAppServerTransport(
            initialLines: [
                #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
                #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
                #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
                #"{"method":"item/agentMessage/delta","params":{"delta":"Working"}}"#
            ],
            interruptCompletionLines: [
                #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"interrupted"}}}"#,
                #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-10","items":[],"status":"inProgress"}}}"#,
                #"{"method":"item/agentMessage/delta","params":{"delta":"Still here"}}"#,
                #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-10","items":[],"status":"completed"}}}"#
            ]
        )
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: {
                await factoryCallCount.increment()
                return transport
            },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.streamText == "Working" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.stopCurrentRun()
        for _ in 0..<40 {
            if manager.latestResultSummary == "Stopped." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.handleFinalTranscriptForTesting("use computer use to keep going")
        for _ in 0..<40 {
            if manager.latestResultSummary == "Still here" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        let interrupt = try #require(sentMessages.first { $0["method"] as? String == "turn/interrupt" })
        let interruptParams = try #require(interrupt["params"] as? [String: Any])
        let turnStarts = sentMessages.filter { $0["method"] as? String == "turn/start" }

        #expect(interruptParams["threadId"] as? String == "thread-1")
        #expect(interruptParams["turnId"] as? String == "turn-9")
        #expect(turnStarts.count == 2)
        #expect(turnStarts.compactMap { ($0["params"] as? [String: Any])?["threadId"] as? String } == ["thread-1", "thread-1"])
        #expect(await factoryCallCount.value == 1)
        #expect(!(await transport.didTerminate))
    }

    private func isOrderedSubsequence(
        _ expected: [LoreleiRunStatus],
        of recorded: [LoreleiRunStatus]
    ) -> Bool {
        var remaining = expected[...]
        for status in recorded {
            if status == remaining.first {
                remaining = remaining.dropFirst()
            }
        }
        return remaining.isEmpty
    }

    @Test func companionManagerShowsNeedsApprovalStatusDuringApprovalBridge() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerApprovalRunStatusTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerApprovalRunStatusTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":44,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow control?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow."},{"label":"Decline","description":"Stop."}]}]}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(5)
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .needsApproval("Computer Use"))

        manager.acceptPendingApproval()
        for _ in 0..<20 {
            if case .working = manager.runStatus {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .working("Thinking…"))
        await transport.enqueue(#"{"method":"item/agentMessage/delta","params":{"delta":"Approved"}}"#)
        await transport.enqueue(#"{"method":"turn/completed","params":{"status":"completed"}}"#)
    }

    @Test func companionManagerStopTerminatesLiveTransport() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerStopRunTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerStopRunTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        let recorder = RunStatusRecorder()
        let statusCancellable = manager.$runStatus.sink { recorder.record($0) }
        defer { statusCancellable.cancel() }

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if recorder.statuses.contains(.working("Thinking…")) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.stopCurrentRun()
        for _ in 0..<20 {
            if await transport.didTerminate {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await transport.didTerminate)
        #expect(manager.latestResultSummary == "Stopped.")
        #expect(manager.runStatus == .finished(success: false))
    }

    @Test func companionManagerPlaysFailureCueOnStop() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerAudioStopTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerAudioStopTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if manager.runStatus == .working("Thinking…") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.stopCurrentRun()

        // Stop now resolves asynchronously (interrupt-or-invalidate hops to a
        // main-actor task), so poll for the cue instead of asserting one tick
        // after the call.
        let expectedEvent = BuddyAudioFeedbackRecorder.Event(cue: .runFailed, spokenSummary: "Stopped.")
        for _ in 0..<100 {
            if audioFeedback.events.contains(expectedEvent) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(audioFeedback.events.contains(expectedEvent))
    }

    @Test func companionManagerPlaysApprovalCue() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerAudioApprovalTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerAudioApprovalTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":44,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow control?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow."},{"label":"Decline","description":"Stop."}]}]}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(audioFeedback.events.filter { $0.cue == .approvalRequested }.count == 1)
        #expect(audioFeedback.events.first { $0.cue == .approvalRequested }?.spokenSummary == nil)
    }

    @Test func companionManagerStopWithoutRunIsNoOp() {
        let defaults = UserDefaults(suiteName: "CompanionManagerStopWithoutRunTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerStopWithoutRunTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.stopCurrentRun()

        #expect(manager.runStatus == .idle)
        #expect(manager.latestResultSummary == nil)
        #expect(manager.pendingApprovalTitle == nil)
    }

    private func foregroundToolRequest(
        arguments: CodexAppServerJSONValue
    ) -> CodexAppServerDynamicToolCallRequest {
        CodexAppServerDynamicToolCallRequest(
            requestID: 47,
            callID: "call-1",
            namespace: "lorelei",
            tool: "foreground_app",
            arguments: arguments
        )
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
