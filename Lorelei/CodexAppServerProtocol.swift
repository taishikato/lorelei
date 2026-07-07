//
//  CodexAppServerProtocol.swift
//  Lorelei
//
//  Minimal line-delimited JSON protocol helpers for Codex App Server.
//

import Foundation

enum CodexAppServerInboundEvent: Equatable, Sendable {
    case response(requestID: Int)
    case threadStarted(requestID: Int, threadID: String)
    case turnStarted(threadID: String, turnID: String)
    case agentMessageDelta(String)
    case toolCallCompleted(status: String, failureMessage: String?, name: String?)
    case turnCompleted(status: String)
    case threadWaitingOnApproval(Bool)
    case approvalRequest(CodexAppServerApprovalRequest)
    case dynamicToolCall(CodexAppServerDynamicToolCallRequest)
    case unsupportedServerRequest(requestID: Int, method: String)
    case error(requestID: Int?, message: String)
    case ignored
}

struct CodexAppServerApprovalRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case toolUserInput
        case commandExecution
        case fileChange
        case permissions
        case mcpElicitation
    }

    let requestID: Int
    let kind: Kind
    let title: String
    let detail: String
    let acceptPayload: CodexAppServerApprovalPayload
    let declinePayload: CodexAppServerApprovalPayload
}

struct CodexAppServerDynamicToolSpec: Equatable, Sendable {
    let name: String
    let namespace: String?
    let description: String
    let inputSchema: CodexAppServerJSONValue
}

struct CodexAppServerDynamicToolCallRequest: Equatable, Sendable {
    let requestID: Int
    let callID: String
    let namespace: String?
    let tool: String
    let arguments: CodexAppServerJSONValue
}

enum CodexAppServerDynamicToolContentItem: Equatable, Sendable {
    case text(String)
    case image(dataURL: String)
}

enum CodexAppServerTurnInputItem: Equatable, Sendable {
    case localImage(path: String)
}

struct CodexAppServerDynamicToolCallResult: Equatable, Sendable {
    let success: Bool
    let contentItems: [CodexAppServerDynamicToolContentItem]

    init(success: Bool, contentItems: [CodexAppServerDynamicToolContentItem]) {
        self.success = success
        self.contentItems = contentItems
    }

    init(success: Bool, contentText: String) {
        self.init(success: success, contentItems: [.text(contentText)])
    }
}

enum CodexAppServerJSONValue: Equatable, Sendable {
    case object([String: CodexAppServerJSONValue])
    case array([CodexAppServerJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init?(_ value: Any) {
        switch value {
        case _ as NSNull:
            self = .null
        // JSONSerialization surfaces both numbers and booleans as NSNumber, and
        // `NSNumber as? Bool` also succeeds for integer 0/1 - identify real JSON
        // booleans by CFBoolean type identity so 0/1 stay numeric.
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            self = .bool(value.boolValue)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            var values: [CodexAppServerJSONValue] = []
            values.reserveCapacity(value.count)
            for item in value {
                guard let jsonValue = CodexAppServerJSONValue(item) else {
                    return nil
                }
                values.append(jsonValue)
            }
            self = .array(values)
        case let value as [String: Any]:
            var object: [String: CodexAppServerJSONValue] = [:]
            for (key, item) in value {
                guard let jsonValue = CodexAppServerJSONValue(item) else {
                    return nil
                }
                object[key] = jsonValue
            }
            self = .object(object)
        default:
            return nil
        }
    }

    nonisolated var jsonObject: Any {
        switch self {
        case .object(let object):
            return object.mapValues(\.jsonObject)
        case .array(let values):
            return values.map(\.jsonObject)
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }
}

enum CodexAppServerApprovalPayload: Equatable, Sendable {
    case toolUserInput(questionID: String, answer: String)
    case commandDecision(String)
    case fileChangeDecision(String)
    case permissionsGranted(CodexAppServerJSONValue, scope: String)
    case permissionsDenied
    case mcpElicitationAccept
    case mcpElicitationDecline
    case mcpElicitationCancel
}

enum CodexAppServerModel {
    /// Spec decision: App Server turns run on gpt-5.5, pinned per-turn.
    static let turnModel = "gpt-5.5"
}

enum CodexAppServerProtocol {
    static func initializeRequest(id: Int) -> [String: Any] {
        [
            "id": id,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "lorelei",
                    "title": "Lorelei",
                    "version": "0.1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        ]
    }

    static func initializedNotification() -> [String: Any] {
        [
            "method": "initialized"
        ]
    }

    static func threadStartRequest(
        id: Int,
        cwd: String,
        dynamicTools: [CodexAppServerDynamicToolSpec] = []
    ) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": cwd,
            "approvalPolicy": granularApprovalPolicy(),
            "approvalsReviewer": "user"
        ]
        let configOverrides = desktopActionConfigOverrides()
        if !configOverrides.isEmpty {
            params["config"] = configOverrides
        }
        if !dynamicTools.isEmpty {
            params["dynamicTools"] = dynamicTools.map(dynamicToolSpecObject)
        }

        return [
            "id": id,
            "method": "thread/start",
            "params": params
        ]
    }

    static func turnStartRequest(
        id: Int,
        threadID: String,
        prompt: String,
        cwd: String,
        sandboxPolicy: String? = nil,
        extraInput: [CodexAppServerTurnInputItem] = []
    ) -> [String: Any] {
        let input = textUserInput(prompt: prompt) + extraInput.map(turnInputObject)
        var params: [String: Any] = [
            "threadId": threadID,
            "cwd": cwd,
            "model": CodexAppServerModel.turnModel,
            "input": input,
            "approvalPolicy": granularApprovalPolicy(),
            "approvalsReviewer": "user"
        ]
        if let sandboxPolicy {
            // SandboxPolicy is an internally tagged enum in the app-server
            // schema: {"type": "readOnly"} / {"type": "workspaceWrite"}, not a
            // bare mode string.
            params["sandboxPolicy"] = ["type": sandboxPolicy]
        }

        return [
            "id": id,
            "method": "turn/start",
            "params": params
        ]
    }

    static func turnSteerRequest(
        id: Int,
        threadID: String,
        expectedTurnID: String,
        prompt: String
    ) -> [String: Any] {
        [
            "id": id,
            "method": "turn/steer",
            "params": [
                "threadId": threadID,
                "expectedTurnId": expectedTurnID,
                "input": textUserInput(prompt: prompt)
            ]
        ]
    }

    static func turnInterruptRequest(id: Int, threadID: String, turnID: String) -> [String: Any] {
        [
            "id": id,
            "method": "turn/interrupt",
            "params": [
                "threadId": threadID,
                "turnId": turnID
            ]
        ]
    }

    static func approvalResponse(id: Int, payload: CodexAppServerApprovalPayload) -> [String: Any] {
        switch payload {
        case .toolUserInput(let questionID, let answer):
            return [
                "id": id,
                "result": [
                    "answers": [
                        questionID: [
                            "answers": [answer]
                        ]
                    ]
                ]
            ]
        case .commandDecision(let decision):
            return [
                "id": id,
                "result": [
                    "decision": decision
                ]
            ]
        case .fileChangeDecision(let decision):
            return [
                "id": id,
                "result": [
                    "decision": decision
                ]
            ]
        case .permissionsGranted(let permissions, let scope):
            return [
                "id": id,
                "result": [
                    "permissions": permissions.jsonObject,
                    "scope": scope
                ]
            ]
        case .permissionsDenied:
            return [
                "id": id,
                "result": [
                    "permissions": [:],
                    "scope": "turn"
                ]
            ]
        case .mcpElicitationAccept:
            return [
                "id": id,
                "result": [
                    "action": "accept",
                    "content": [:],
                    "_meta": NSNull()
                ]
            ]
        case .mcpElicitationDecline:
            return [
                "id": id,
                "result": [
                    "action": "decline",
                    "content": NSNull(),
                    "_meta": NSNull()
                ]
            ]
        case .mcpElicitationCancel:
            return [
                "id": id,
                "result": [
                    "action": "cancel",
                    "content": NSNull(),
                    "_meta": NSNull()
                ]
            ]
        }
    }

    static func dynamicToolCallResponse(
        id: Int,
        result: CodexAppServerDynamicToolCallResult
    ) -> [String: Any] {
        [
            "id": id,
            "result": [
                "success": result.success,
                "contentItems": result.contentItems.map { item in
                    switch item {
                    case .text(let text):
                        return [
                            "type": "inputText",
                            "text": text
                        ]
                    case .image(let dataURL):
                        return [
                            "type": "inputImage",
                            "imageUrl": dataURL
                        ]
                    }
                }
            ]
        ]
    }

    static func encodeLine(_ message: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodexAppServerProtocolError.invalidUTF8
        }
        return string + "\n"
    }

    static func parseInboundLine(_ line: String) throws -> CodexAppServerInboundEvent {
        guard let data = line.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAppServerProtocolError.invalidJSON
        }

        if let error = root["error"] as? [String: Any] {
            return .error(
                requestID: root["id"] as? Int,
                message: (error["message"] as? String) ?? "Codex App Server returned an error."
            )
        }

        if let id = root["id"] as? Int,
           let result = root["result"] as? [String: Any] {
            if let thread = result["thread"] as? [String: Any],
               let threadID = thread["id"] as? String {
                return .threadStarted(requestID: id, threadID: threadID)
            }
            return .response(requestID: id)
        }

        guard let method = root["method"] as? String else {
            return .ignored
        }

        let params = root["params"] as? [String: Any] ?? [:]
        switch method {
        case "error":
            if let error = params["error"] as? [String: Any],
               let message = error["message"] as? String {
                return .error(requestID: root["id"] as? Int, message: message)
            }
            return .error(requestID: root["id"] as? Int, message: "Codex App Server returned an error.")
        case "item/agentMessage/delta":
            return .agentMessageDelta((params["delta"] as? String) ?? "")
        case "turn/started":
            guard let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else {
                throw CodexAppServerProtocolError.missingRequiredField
            }
            return .turnStarted(threadID: threadID, turnID: turnID)
        case "item/completed":
            return parseCompletedItem(params: params)
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            return .turnCompleted(status: (params["status"] as? String) ?? (turn?["status"] as? String) ?? "completed")
        case "thread/status/changed":
            return parseThreadStatusChanged(params: params)
        case "item/tool/requestUserInput":
            return .approvalRequest(try parseToolUserInput(root: root, params: params))
        case "item/commandExecution/requestApproval":
            return .approvalRequest(try parseCommandApproval(root: root, params: params))
        case "item/fileChange/requestApproval":
            return .approvalRequest(try parseFileChangeApproval(root: root, params: params))
        case "item/permissions/requestApproval":
            return .approvalRequest(try parsePermissionsApproval(root: root, params: params))
        case "mcpServer/elicitation/request":
            return .approvalRequest(try parseMcpElicitation(root: root, params: params))
        case "item/tool/call":
            return .dynamicToolCall(try parseDynamicToolCall(root: root, params: params))
        default:
            if let requestID = root["id"] as? Int {
                return .unsupportedServerRequest(requestID: requestID, method: method)
            }
            return .ignored
        }
    }

    private static func parseToolUserInput(
        root: [String: Any],
        params: [String: Any]
    ) throws -> CodexAppServerApprovalRequest {
        guard let requestID = root["id"] as? Int,
              let questions = params["questions"] as? [[String: Any]],
              let question = questions.first,
              let questionID = question["id"] as? String else {
            throw CodexAppServerProtocolError.missingRequiredField
        }

        let options = question["options"] as? [[String: Any]] ?? []
        let accept = optionLabel(in: options, matching: ["accept", "approve", "allow", "yes"]) ?? "Accept"
        let decline = optionLabel(in: options, matching: ["decline", "cancel", "deny", "no"]) ?? "Decline"

        return CodexAppServerApprovalRequest(
            requestID: requestID,
            kind: .toolUserInput,
            title: (question["header"] as? String) ?? "Codex approval",
            detail: (question["question"] as? String) ?? "Codex is requesting input.",
            acceptPayload: .toolUserInput(questionID: questionID, answer: accept),
            declinePayload: .toolUserInput(questionID: questionID, answer: decline)
        )
    }

    private static func parseCommandApproval(
        root: [String: Any],
        params: [String: Any]
    ) throws -> CodexAppServerApprovalRequest {
        guard let requestID = root["id"] as? Int else {
            throw CodexAppServerProtocolError.missingRequiredField
        }

        let reason = (params["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = (params["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [reason, command]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")

        return CodexAppServerApprovalRequest(
            requestID: requestID,
            kind: .commandExecution,
            title: "Codex command approval",
            detail: detail.isEmpty ? "Codex wants to run a command." : detail,
            acceptPayload: .commandDecision("accept"),
            declinePayload: .commandDecision("cancel")
        )
    }

    private static func parseFileChangeApproval(
        root: [String: Any],
        params: [String: Any]
    ) throws -> CodexAppServerApprovalRequest {
        guard let requestID = root["id"] as? Int else {
            throw CodexAppServerProtocolError.missingRequiredField
        }

        let reason = (params["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let grantRoot = (params["grantRoot"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [reason, grantRoot]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")

        return CodexAppServerApprovalRequest(
            requestID: requestID,
            kind: .fileChange,
            title: "Codex file-change approval",
            detail: detail.isEmpty ? "Codex wants to change files." : detail,
            acceptPayload: .fileChangeDecision("accept"),
            declinePayload: .fileChangeDecision("cancel")
        )
    }

    private static func parseThreadStatusChanged(params: [String: Any]) -> CodexAppServerInboundEvent {
        let statusObject = params["status"] as? [String: Any]
        let statusType = (statusObject?["type"] as? String) ?? (params["status"] as? String)
        let activeFlags = (statusObject?["activeFlags"] as? [String])
            ?? (params["activeFlags"] as? [String])
            ?? []

        guard statusType == "active" else {
            return .threadWaitingOnApproval(false)
        }

        return .threadWaitingOnApproval(activeFlags.contains("waitingOnApproval"))
    }

    private static func parsePermissionsApproval(
        root: [String: Any],
        params: [String: Any]
    ) throws -> CodexAppServerApprovalRequest {
        guard let requestID = root["id"] as? Int,
              let requestedPermissions = CodexAppServerJSONValue(params["permissions"] ?? [:]) else {
            throw CodexAppServerProtocolError.missingRequiredField
        }

        let grantedPermissions = grantedPermissions(from: requestedPermissions)
        let reason = (params["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let permissionsSummary = permissionsSummary(from: grantedPermissions)
        let detail = [reason, permissionsSummary]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")

        return CodexAppServerApprovalRequest(
            requestID: requestID,
            kind: .permissions,
            title: "Codex permissions approval",
            detail: detail.isEmpty ? "Codex wants additional permissions." : detail,
            acceptPayload: .permissionsGranted(grantedPermissions, scope: "turn"),
            declinePayload: .permissionsDenied
        )
    }

    private static func parseMcpElicitation(
        root: [String: Any],
        params: [String: Any]
    ) throws -> CodexAppServerApprovalRequest {
        guard let requestID = root["id"] as? Int else {
            throw CodexAppServerProtocolError.missingRequiredField
        }

        let serverName = (params["serverName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = ((params["message"] as? String) ?? "Codex is requesting MCP approval.")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "MCP server approval"
        let serverDetail = serverName.map { "Server: \($0)" }
        let detail = [message.isEmpty ? nil : message, serverDetail]
            .compactMap { $0 }
            .joined(separator: "\n")

        return CodexAppServerApprovalRequest(
            requestID: requestID,
            kind: .mcpElicitation,
            title: title,
            detail: detail.isEmpty ? "Codex is requesting MCP approval." : detail,
            acceptPayload: .mcpElicitationAccept,
            declinePayload: .mcpElicitationDecline
        )
    }

    private static func parseDynamicToolCall(
        root: [String: Any],
        params: [String: Any]
    ) throws -> CodexAppServerDynamicToolCallRequest {
        guard let requestID = root["id"] as? Int,
              let callID = params["callId"] as? String,
              let tool = params["tool"] as? String,
              let arguments = CodexAppServerJSONValue(params["arguments"] ?? [:]) else {
            throw CodexAppServerProtocolError.missingRequiredField
        }

        return CodexAppServerDynamicToolCallRequest(
            requestID: requestID,
            callID: callID,
            namespace: params["namespace"] as? String,
            tool: tool,
            arguments: arguments
        )
    }

    private static func parseCompletedItem(params: [String: Any]) -> CodexAppServerInboundEvent {
        guard let item = params["item"] as? [String: Any],
              item["type"] as? String == "mcpToolCall" else {
            return .ignored
        }

        let status = (item["status"] as? String)
            ?? (params["status"] as? String)
            ?? "completed"
        return .toolCallCompleted(
            status: status,
            failureMessage: status == "failed" ? mcpToolFailureMessage(from: item) : nil,
            name: mcpToolName(from: item)
        )
    }

    private static func mcpToolName(from item: [String: Any]) -> String? {
        let server = trimmedString(item["server"])
        let tool = trimmedString(item["tool"])

        switch (server, tool) {
        case let (server?, tool?):
            return "\(server).\(tool)"
        case let (nil, tool?):
            return tool
        default:
            return nil
        }
    }

    private static func mcpToolFailureMessage(from item: [String: Any]) -> String? {
        if let message = trimmedString(item["error"]) {
            return message
        }

        guard let result = item["result"] as? [String: Any] else {
            return nil
        }

        if let message = trimmedString(result["message"]) {
            return message
        }

        if let content = result["content"] as? [[String: Any]] {
            let text = content
                .compactMap { trimmedString($0["text"]) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }

        return nil
    }

    private static func trimmedString(_ value: Any?) -> String? {
        let text: String?
        if let value = value as? String {
            text = value
        } else if let value = value as? [String: Any] {
            text = value["message"] as? String
        } else {
            text = nil
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func grantedPermissions(from requestedPermissions: CodexAppServerJSONValue) -> CodexAppServerJSONValue {
        guard case .object(let object) = requestedPermissions else {
            return .object([:])
        }

        var granted: [String: CodexAppServerJSONValue] = [:]
        for key in ["network", "fileSystem"] {
            guard let value = object[key], value != .null else {
                continue
            }
            granted[key] = value
        }
        return .object(granted)
    }

    private static func permissionsSummary(from grantedPermissions: CodexAppServerJSONValue) -> String? {
        guard case .object(let object) = grantedPermissions else {
            return nil
        }

        let names = ["network", "fileSystem"].filter { object[$0] != nil }
        guard !names.isEmpty else {
            return nil
        }
        return "Permissions: " + names.joined(separator: ", ")
    }

    private static func optionLabel(in options: [[String: Any]], matching candidates: [String]) -> String? {
        for candidate in candidates {
            if let label = options.compactMap({ $0["label"] as? String }).first(where: {
                $0.localizedCaseInsensitiveContains(candidate)
            }) {
                return label
            }
        }
        return nil
    }

    private static func textUserInput(prompt: String) -> [[String: Any]] {
        [
            [
                "type": "text",
                "text": prompt,
                "text_elements": []
            ]
        ]
    }

    nonisolated private static func turnInputObject(_ item: CodexAppServerTurnInputItem) -> [String: Any] {
        switch item {
        case .localImage(let path):
            return [
                "type": "localImage",
                "path": path
            ]
        }
    }

    private static func granularApprovalPolicy() -> [String: Any] {
        [
            "granular": [
                "sandbox_approval": true,
                "rules": true,
                "skill_approval": true,
                "request_permissions": true,
                "mcp_elicitations": true
            ]
        ]
    }

    private static func desktopActionConfigOverrides() -> [String: Any] {
        [:]
    }

    nonisolated private static func dynamicToolSpecObject(_ spec: CodexAppServerDynamicToolSpec) -> [String: Any] {
        var object: [String: Any] = [
            "name": spec.name,
            "description": spec.description,
            "inputSchema": spec.inputSchema.jsonObject
        ]
        if let namespace = spec.namespace {
            object["namespace"] = namespace
        }
        return object
    }
}

enum CodexAppServerProtocolError: Error, Equatable {
    case invalidJSON
    case invalidUTF8
    case missingRequiredField
}
