//
//  AXDesktopActionExecutor.swift
//  Lorelei
//
//  Accessibility-backed desktop action executor.
//

import AppKit
import ApplicationServices
import Foundation

/// Value tree decoupled from AX so serialization/registry are unit-testable.
struct DesktopUINode: Equatable, Sendable {
    let role: String
    let title: String?
    let value: String?
    let frame: CGRect?
    let isEnabled: Bool
    let isFocused: Bool
    let children: [DesktopUINode]
}

@MainActor
final class AXDesktopActionExecutor: DesktopActionExecuting {
    private static let maxAcceptedElements = 400
    private static let maxDepth = 12
    private static let structuralRoles: Set<String> = [
        "AXGroup",
        "AXUnknown",
        "AXSplitGroup",
        "AXScrollArea"
    ]

    private let hasAccessibilityPermission: @MainActor () -> Bool
    private var elementRegistry: [String: Int] = [:]
    private var elements: [AXUIElement] = []

    init(hasAccessibilityPermission: @escaping @MainActor () -> Bool = WindowPositionManager.hasAccessibilityPermission) {
        self.hasAccessibilityPermission = hasAccessibilityPermission
    }

    static func serialize(
        _ root: DesktopUINode,
        assigningIDsInto registry: inout [String: Int]
    ) -> DesktopSnapshotResult {
        var lines: [String] = []
        var acceptedCount = 0
        var omittedCount = 0
        registry.removeAll()

        serializeNode(
            root,
            depth: 0,
            registry: &registry,
            lines: &lines,
            acceptedCount: &acceptedCount,
            omittedCount: &omittedCount
        )

        if omittedCount > 0 {
            lines.append("… truncated (\(omittedCount) elements omitted)")
        }

        return DesktopSnapshotResult(
            text: lines.joined(separator: "\n"),
            elementCount: acceptedCount
        )
    }

    func snapshot(appName: String?) async -> Result<DesktopSnapshotResult, DesktopActionError> {
        elementRegistry.removeAll()
        elements.removeAll()

        guard hasAccessibilityPermission() else {
            return .failure(.accessibilityPermissionMissing)
        }
        guard let app = resolveApplication(named: appName) else {
            return .failure(.appNotFound(appName ?? "frontmost application"))
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let traversal = buildNodeAndAcceptedElements(from: appElement, depth: 0)
        var newRegistry: [String: Int] = [:]
        let result = Self.serialize(traversal.node, assigningIDsInto: &newRegistry)

        elementRegistry = newRegistry
        elements = Array(traversal.acceptedElements.prefix(Self.maxAcceptedElements))

        return .success(result)
    }

    func perform(_ action: DesktopElementAction, elementID: String) async -> DesktopActionOutcome {
        guard let element = element(for: elementID) else {
            return DesktopActionOutcome(
                success: false,
                message: DesktopActionError.staleElementID(elementID).toolMessage
            )
        }

        let error: AXError
        switch action {
        case .press:
            error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        case .raise:
            error = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        case .focus:
            error = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }

        if error == .success {
            return DesktopActionOutcome(success: true, message: "ok")
        }
        return DesktopActionOutcome(
            success: false,
            message: "Accessibility action failed for elementId '\(elementID)' with AXError \(error.rawValue)."
        )
    }

    func setText(
        _ text: String,
        elementID: String,
        mode: DesktopSetTextMode
    ) async -> DesktopActionOutcome {
        guard let element = element(for: elementID) else {
            return DesktopActionOutcome(
                success: false,
                message: DesktopActionError.staleElementID(elementID).toolMessage
            )
        }

        let attribute = mode == .replace ? kAXValueAttribute : kAXSelectedTextAttribute
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, text as CFString)

        if error == .success {
            return DesktopActionOutcome(success: true, message: "ok")
        }
        return DesktopActionOutcome(
            success: false,
            message: "Accessibility text update failed for elementId '\(elementID)' with AXError \(error.rawValue)."
        )
    }

    func screenshot() async -> Result<Data, DesktopActionError> {
        do {
            let data = try await CompanionScreenCaptureUtility.captureCursorScreenAsPNG(maxDimension: 1568)
            return .success(data)
        } catch {
            return .failure(.captureFailed(error.localizedDescription))
        }
    }

    private static func serializeNode(
        _ node: DesktopUINode,
        depth: Int,
        registry: inout [String: Int],
        lines: inout [String],
        acceptedCount: inout Int,
        omittedCount: inout Int
    ) {
        guard depth <= maxDepth else {
            omittedCount += countAcceptedNodes(node)
            return
        }

        if shouldList(node) {
            if acceptedCount >= maxAcceptedElements {
                omittedCount += countAcceptedNodes(node)
                return
            }

            acceptedCount += 1
            let elementID = "e\(acceptedCount)"
            registry[elementID] = acceptedCount - 1
            lines.append(line(for: node, elementID: elementID, depth: depth))

            for child in node.children {
                serializeNode(
                    child,
                    depth: depth + 1,
                    registry: &registry,
                    lines: &lines,
                    acceptedCount: &acceptedCount,
                    omittedCount: &omittedCount
                )
            }
        } else {
            for child in node.children {
                serializeNode(
                    child,
                    depth: depth,
                    registry: &registry,
                    lines: &lines,
                    acceptedCount: &acceptedCount,
                    omittedCount: &omittedCount
                )
            }
        }
    }

    private static func shouldList(_ node: DesktopUINode) -> Bool {
        if hasText(node.title) || hasText(node.value) {
            return true
        }
        return !structuralRoles.contains(node.role)
    }

    private static func countAcceptedNodes(_ node: DesktopUINode) -> Int {
        let current = shouldList(node) ? 1 : 0
        return current + node.children.reduce(0) { $0 + countAcceptedNodes($1) }
    }

    private static func line(for node: DesktopUINode, elementID: String, depth: Int) -> String {
        var line = String(repeating: "  ", count: depth) + "[\(elementID)] \(node.role)"
        if let title = normalizedText(node.title) {
            line += " \"\(escaped(title))\""
        }
        if let value = normalizedText(node.value) {
            line += " value=\"\(escaped(truncated(value)))\""
        }
        if node.role == "AXWindow", let frame = node.frame {
            line += " (\(rounded(frame.origin.x)),\(rounded(frame.origin.y)) \(rounded(frame.width))x\(rounded(frame.height)))"
        }
        if node.isFocused {
            line += " focused"
        }
        if !node.isEnabled {
            line += " disabled"
        }
        return line
    }

    private static func rounded(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }

    private static func truncated(_ value: String) -> String {
        guard value.count > 80 else {
            return value
        }
        return String(value.prefix(79)) + "…"
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func hasText(_ value: String?) -> Bool {
        normalizedText(value) != nil
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolveApplication(named appName: String?) -> NSRunningApplication? {
        guard let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NSWorkspace.shared.frontmostApplication
        }

        return NSWorkspace.shared.runningApplications.first { app in
            app.localizedName?.localizedCaseInsensitiveContains(appName) == true
        }
    }

    private func element(for elementID: String) -> AXUIElement? {
        guard let index = elementRegistry[elementID],
              elements.indices.contains(index) else {
            return nil
        }
        return elements[index]
    }

    private func buildNodeAndAcceptedElements(
        from element: AXUIElement,
        depth: Int
    ) -> (node: DesktopUINode, acceptedElements: [AXUIElement]) {
        let childElements = depth >= Self.maxDepth ? [] : axChildren(of: element)
        let traversedChildren = childElements.map {
            buildNodeAndAcceptedElements(from: $0, depth: depth + 1)
        }

        let node = DesktopUINode(
            role: stringAttribute(kAXRoleAttribute as CFString, of: element) ?? "AXUnknown",
            title: firstTextAttribute(
                [kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString, "AXLabel" as CFString],
                of: element
            ),
            value: valueString(of: element),
            frame: frame(of: element),
            isEnabled: boolAttribute(kAXEnabledAttribute as CFString, of: element) ?? true,
            isFocused: boolAttribute(kAXFocusedAttribute as CFString, of: element) ?? false,
            children: traversedChildren.map(\.node)
        )

        var acceptedElements: [AXUIElement] = []
        if Self.shouldList(node) {
            acceptedElements.append(element)
        }
        acceptedElements.append(contentsOf: traversedChildren.flatMap(\.acceptedElements))
        return (node, acceptedElements)
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        guard let children: [AXUIElement] = attribute(kAXChildrenAttribute as CFString, of: element) else {
            return []
        }
        return children
    }

    private func firstTextAttribute(_ names: [CFString], of element: AXUIElement) -> String? {
        for name in names {
            if let value = stringAttribute(name, of: element),
               Self.normalizedText(value) != nil {
                return value
            }
        }
        return nil
    }

    private func stringAttribute(_ name: CFString, of element: AXUIElement) -> String? {
        attribute(name, of: element) as String?
    }

    private func boolAttribute(_ name: CFString, of element: AXUIElement) -> Bool? {
        attribute(name, of: element) as Bool?
    }

    private func valueString(of element: AXUIElement) -> String? {
        guard let value: AnyObject = attribute(kAXValueAttribute as CFString, of: element) else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        if let frameValue: AXValue = attribute("AXFrame" as CFString, of: element) {
            var frame = CGRect.zero
            if AXValueGetValue(frameValue, .cgRect, &frame) {
                return frame
            }
        }

        guard let positionValue: AXValue = attribute(kAXPositionAttribute as CFString, of: element),
              let sizeValue: AXValue = attribute(kAXSizeAttribute as CFString, of: element) else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private func attribute<T>(_ name: CFString, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value as? T
    }
}
