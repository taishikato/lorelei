//
//  CodexAppServerMemoryToolSuite.swift
//  Lorelei
//
//  Dynamic tool for replacing Lorelei's local memory files.
//

import Foundation

enum CodexAppServerMemoryToolSuite {
    private static let namespace = "lorelei"

    static func toolSpecs() -> [CodexAppServerDynamicToolSpec] {
        [
            CodexAppServerDynamicToolSpec(
                name: "memory_write",
                namespace: namespace,
                description: "Use this to persist durable user preferences or habits in profile memory, or current project context in volatile memory. Keep both files short, curated Markdown. Never store secrets, raw transcripts, or screen content verbatim.",
                inputSchema: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("file"), .string("content")]),
                    "properties": .object([
                        "file": .object([
                            "type": .string("string"),
                            "enum": .array([.string("profile"), .string("volatile")]),
                            "description": .string("Memory file to replace.")
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("Complete new Markdown content of the memory file. This fully replaces its current content.")
                        ])
                    ])
                ])
            )
        ]
    }

    static func handle(
        _ request: CodexAppServerDynamicToolCallRequest,
        store: LoreleiMemoryStore,
        workspacePath: String?
    ) -> CodexAppServerDynamicToolCallResult {
        guard request.namespace == namespace, request.tool == "memory_write" else {
            return .failure("Unsupported dynamic tool: \(qualifiedName(request))")
        }
        guard case .object(let arguments) = request.arguments else {
            return .failure("memory_write arguments must be an object with file and content.")
        }
        guard case .string(let file) = arguments["file"] else {
            return .failure("memory_write requires file to be profile or volatile.")
        }
        guard case .string(let content) = arguments["content"] else {
            return .failure("memory_write requires content as a string.")
        }

        do {
            switch file {
            case "profile":
                try store.writeProfile(content)
            case "volatile":
                try store.writeVolatile(content, forWorkspacePath: workspacePath)
            default:
                return .failure("memory_write file must be profile or volatile.")
            }
            return .success("Memory updated.")
        } catch {
            return .failure("Memory could not be updated: \(error.localizedDescription)")
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
