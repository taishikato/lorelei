//
//  CodexAppServerDesktopToolSuite.swift
//  Lorelei
//
//  Dynamic tools that translate App Server calls into DesktopActionExecuting requests.
//

import Foundation

enum CodexAppServerDesktopToolSuite {
    private static let namespace = "lorelei"

    static func toolSpecs() -> [CodexAppServerDynamicToolSpec] {
        [
            CodexAppServerDynamicToolSpec(
                name: "desktop_snapshot",
                namespace: namespace,
                description: "Read the accessibility tree for the frontmost app, or for a named running app.",
                inputSchema: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "app": .object([
                            "type": .string("string"),
                            "description": .string("Optional human-readable running app name. Omit for the frontmost app.")
                        ])
                    ])
                ])
            ),
            CodexAppServerDynamicToolSpec(
                name: "desktop_action",
                namespace: namespace,
                description: "Perform an accessibility action on an element from the latest lorelei.desktop_snapshot.",
                inputSchema: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("elementId"), .string("action")]),
                    "properties": .object([
                        "elementId": .object([
                            "type": .string("string"),
                            "description": .string("Element ID from the latest lorelei.desktop_snapshot, for example e2.")
                        ]),
                        "action": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("press"),
                                .string("focus"),
                                .string("raise"),
                                .string("open"),
                                .string("select"),
                                .string("showMenu")
                            ]),
                            "description": .string("Accessibility action to perform.")
                        ])
                    ])
                ])
            ),
            CodexAppServerDynamicToolSpec(
                name: "set_text",
                namespace: namespace,
                description: "Set text through accessibility values. Use this for text entry, including non-ASCII text.",
                inputSchema: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("elementId"), .string("text")]),
                    "properties": .object([
                        "elementId": .object([
                            "type": .string("string"),
                            "description": .string("Element ID from the latest lorelei.desktop_snapshot, for example e2.")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("Text to set directly through accessibility APIs.")
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array([.string("replace"), .string("insert")]),
                            "description": .string("replace sets the full value; insert inserts at the current selection. Defaults to replace.")
                        ])
                    ])
                ])
            ),
            CodexAppServerDynamicToolSpec(
                name: "screenshot",
                namespace: namespace,
                description: "Fallback visual capture for when lorelei.desktop_snapshot does not expose the needed information, such as canvas or Electron app content. Use the accessibility snapshot first when possible.",
                inputSchema: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([:])
                ])
            )
        ]
    }

    @MainActor
    static func handle(
        _ request: CodexAppServerDynamicToolCallRequest,
        executor: any DesktopActionExecuting
    ) async -> CodexAppServerDynamicToolCallResult {
        guard request.namespace == namespace else {
            return .failure("Unsupported dynamic tool namespace for \(qualifiedName(request)).")
        }

        switch request.tool {
        case "desktop_snapshot":
            return await handleSnapshot(request, executor: executor)
        case "desktop_action":
            return await handleAction(request, executor: executor)
        case "set_text":
            return await handleSetText(request, executor: executor)
        case "screenshot":
            return await handleScreenshot(executor: executor)
        default:
            return .failure("Unsupported dynamic tool: \(qualifiedName(request))")
        }
    }

    @MainActor
    private static func handleSnapshot(
        _ request: CodexAppServerDynamicToolCallRequest,
        executor: any DesktopActionExecuting
    ) async -> CodexAppServerDynamicToolCallResult {
        let arguments = request.arguments.objectValue
        let appName: String?
        if let appValue = arguments?["app"] {
            guard let value = appValue.trimmedStringValue else {
                return .failure("desktop_snapshot app must be a non-empty string when provided.")
            }
            appName = value
        } else {
            appName = nil
        }

        switch await executor.snapshot(appName: appName) {
        case .success(let result):
            return .success(result.text)
        case .failure(let error):
            return .failure(error.toolMessage)
        }
    }

    @MainActor
    private static func handleAction(
        _ request: CodexAppServerDynamicToolCallRequest,
        executor: any DesktopActionExecuting
    ) async -> CodexAppServerDynamicToolCallResult {
        guard let arguments = request.arguments.objectValue else {
            return .failure("desktop_action arguments must be an object with elementId and action.")
        }
        guard let elementID = arguments["elementId"]?.trimmedStringValue else {
            return .failure("desktop_action requires elementId from the latest lorelei.desktop_snapshot.")
        }
        guard let actionText = arguments["action"]?.trimmedStringValue else {
            return .failure("desktop_action requires action: press, focus, raise, open, select, or showMenu.")
        }
        guard let action = DesktopElementAction(rawValue: actionText) else {
            return .failure("desktop_action action must be one of: press, focus, raise, open, select, showMenu.")
        }

        let outcome = await executor.perform(action, elementID: elementID)
        return CodexAppServerDynamicToolCallResult(success: outcome.success, contentText: outcome.message)
    }

    @MainActor
    private static func handleSetText(
        _ request: CodexAppServerDynamicToolCallRequest,
        executor: any DesktopActionExecuting
    ) async -> CodexAppServerDynamicToolCallResult {
        guard let arguments = request.arguments.objectValue else {
            return .failure("set_text arguments must be an object with elementId and text.")
        }
        guard let elementID = arguments["elementId"]?.trimmedStringValue else {
            return .failure("set_text requires elementId from the latest lorelei.desktop_snapshot.")
        }
        guard case .string(let text) = arguments["text"] else {
            return .failure("set_text requires text as a string.")
        }

        let mode: DesktopSetTextMode
        if let modeValue = arguments["mode"] {
            guard let modeText = modeValue.trimmedStringValue,
                  let parsedMode = DesktopSetTextMode(rawValue: modeText) else {
                return .failure("set_text mode must be replace or insert.")
            }
            mode = parsedMode
        } else {
            mode = .replace
        }

        let outcome = await executor.setText(text, elementID: elementID, mode: mode)
        return CodexAppServerDynamicToolCallResult(success: outcome.success, contentText: outcome.message)
    }

    @MainActor
    private static func handleScreenshot(
        executor: any DesktopActionExecuting
    ) async -> CodexAppServerDynamicToolCallResult {
        switch await executor.screenshot() {
        case .success(let data):
            let dataURL = "data:image/png;base64,\(data.base64EncodedString())"
            return CodexAppServerDynamicToolCallResult(
                success: true,
                contentItems: [.image(dataURL: dataURL)]
            )
        case .failure(let error):
            return .failure(error.toolMessage)
        }
    }

    private static func qualifiedName(_ request: CodexAppServerDynamicToolCallRequest) -> String {
        "\(request.namespace.map { "\($0)." } ?? "")\(request.tool)"
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
    var objectValue: [String: CodexAppServerJSONValue]? {
        guard case .object(let object) = self else {
            return nil
        }
        return object
    }

    var trimmedStringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
