//
//  AppServerProtocolTests.swift
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
struct AppServerProtocolTests {

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
}
