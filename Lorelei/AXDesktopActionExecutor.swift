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
    let roleDescription: String?
    let value: String?
    let hint: String?
    let frame: CGRect?
    let isEnabled: Bool
    let isFocused: Bool
    let supportedActions: [DesktopElementAction]
    let omittedChildCount: Int
    let children: [DesktopUINode]

    init(
        role: String,
        title: String?,
        roleDescription: String? = nil,
        value: String?,
        hint: String? = nil,
        frame: CGRect?,
        isEnabled: Bool,
        isFocused: Bool,
        supportedActions: [DesktopElementAction] = [],
        omittedChildCount: Int = 0,
        children: [DesktopUINode]
    ) {
        self.role = role
        self.title = title
        self.roleDescription = roleDescription
        self.value = value
        self.hint = hint
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.supportedActions = supportedActions
        self.omittedChildCount = omittedChildCount
        self.children = children
    }
}

@MainActor
final class AXDesktopActionExecutor: DesktopActionExecuting {
    private static let maxAcceptedElements = 400
    private static let maxDepth = 12
    private static let maxLargeContainerChildren = 24
    private static let maxMenuSubtreeElements = 120
    private static let axOpenAction = "AXOpen"
    private static let structuralRoles: Set<String> = [
        "AXGroup",
        "AXUnknown",
        "AXSplitGroup",
        "AXScrollArea"
    ]
    private static let largeCollectionRoles: Set<String> = [
        "AXList",
        "AXMenu",
        "AXTable",
        "AXOutline",
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
        assigningIDsInto registry: inout [String: Int],
        focusedLine: (node: DesktopUINode, elementID: String, registryIndex: Int)? = nil
    ) -> DesktopSnapshotResult {
        var lines: [String] = []
        var acceptedCount = 0
        var menuAcceptedCount = 0
        var omittedCount = 0
        registry.removeAll()

        serializeNode(
            root,
            depth: 0,
            isInMenuSubtree: false,
            registry: &registry,
            lines: &lines,
            acceptedCount: &acceptedCount,
            menuAcceptedCount: &menuAcceptedCount,
            omittedCount: &omittedCount
        )

        if let focusedLine {
            registry[focusedLine.elementID] = focusedLine.registryIndex
            lines.insert(
                "[focused] \(line(for: focusedLine.node, elementID: focusedLine.elementID, depth: 0))",
                at: 0
            )
            if Int(focusedLine.elementID.dropFirst()) ?? 0 > acceptedCount {
                acceptedCount += 1
            }
        }

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
        let focusedElement: AXUIElement? = attribute(kAXFocusedUIElementAttribute as CFString, of: appElement)
        var menuAcceptedCount = 0
        guard let traversal = buildNodeAndAcceptedElements(
            from: appElement,
            depth: 0,
            isInMenuSubtree: false,
            menuAcceptedCount: &menuAcceptedCount
        ) else {
            return .failure(.captureFailed("Accessibility snapshot could not read the application root."))
        }
        var newRegistry: [String: Int] = [:]
        var acceptedElements = Array(traversal.acceptedElements.prefix(Self.maxAcceptedElements))
        let focusedIndex = focusedElement.flatMap { index(of: $0, in: acceptedElements) }
        let focusedLine: (node: DesktopUINode, elementID: String, registryIndex: Int)?
        if let focusedElement, let focusedNode = buildSingleNode(from: focusedElement) {
            if let focusedIndex {
                focusedLine = (node: focusedNode, elementID: "e\(focusedIndex + 1)", registryIndex: focusedIndex)
            } else {
                let focusedRegistryIndex = acceptedElements.count
                acceptedElements.append(focusedElement)
                focusedLine = (
                    node: focusedNode,
                    elementID: "e\(acceptedElements.count)",
                    registryIndex: focusedRegistryIndex
                )
            }
        } else {
            focusedLine = nil
        }
        let result = Self.serialize(
            traversal.node,
            assigningIDsInto: &newRegistry,
            focusedLine: focusedLine
        )

        elementRegistry = newRegistry
        elements = acceptedElements

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
        case .open:
            error = AXUIElementPerformAction(element, Self.axOpenAction as CFString)
        case .showMenu:
            error = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
        case .raise:
            error = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        case .focus:
            error = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        case .select:
            error = AXUIElementSetAttributeValue(
                element,
                kAXSelectedAttribute as CFString,
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
        isInMenuSubtree: Bool,
        registry: inout [String: Int],
        lines: inout [String],
        acceptedCount: inout Int,
        menuAcceptedCount: inout Int,
        omittedCount: inout Int
    ) {
        guard depth <= maxDepth else {
            omittedCount += countAcceptedNodes(node)
            return
        }

        let nodeIsInMenuSubtree = isInMenuSubtree || node.role == "AXMenu"
        if shouldList(node) {
            if acceptedCount >= maxAcceptedElements {
                omittedCount += countAcceptedNodes(node)
                return
            }
            if nodeIsInMenuSubtree {
                guard menuAcceptedCount < maxMenuSubtreeElements else {
                    omittedCount += countAcceptedNodes(node)
                    return
                }
                menuAcceptedCount += 1
            }

            acceptedCount += 1
            let elementID = "e\(acceptedCount)"
            registry[elementID] = acceptedCount - 1
            lines.append(line(for: node, elementID: elementID, depth: depth))

            let budgetedChildren = prioritizedBudgetedChildren(of: node)
            for child in budgetedChildren.children {
                serializeNode(
                    child,
                    depth: depth + 1,
                    isInMenuSubtree: nodeIsInMenuSubtree,
                    registry: &registry,
                    lines: &lines,
                    acceptedCount: &acceptedCount,
                    menuAcceptedCount: &menuAcceptedCount,
                    omittedCount: &omittedCount
                )
            }
            let rowOmissionCount = node.omittedChildCount + budgetedChildren.omittedCount
            if rowOmissionCount > 0 {
                lines.append(String(repeating: "  ", count: depth + 1) + "… (+\(rowOmissionCount) more rows)")
            }
        } else {
            let budgetedChildren = prioritizedBudgetedChildren(of: node)
            for child in budgetedChildren.children {
                serializeNode(
                    child,
                    depth: depth,
                    isInMenuSubtree: nodeIsInMenuSubtree,
                    registry: &registry,
                    lines: &lines,
                    acceptedCount: &acceptedCount,
                    menuAcceptedCount: &menuAcceptedCount,
                    omittedCount: &omittedCount
                )
            }
            let rowOmissionCount = node.omittedChildCount + budgetedChildren.omittedCount
            if rowOmissionCount > 0 {
                lines.append(String(repeating: "  ", count: depth) + "… (+\(rowOmissionCount) more rows)")
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
        let children = prioritizedBudgetedChildren(of: node).children
        return current + children.reduce(0) { $0 + countAcceptedNodes($1) }
    }

    private static func line(for node: DesktopUINode, elementID: String, depth: Int) -> String {
        var line = String(repeating: "  ", count: depth) + "[\(elementID)] \(node.role)"
        if let title = normalizedText(node.title) {
            line += " \"\(escaped(title))\""
        }
        if let roleDescription = additionalText(node.roleDescription, beyond: [node.title, node.role]) {
            line += " roleDescription=\"\(escaped(truncated(roleDescription)))\""
        }
        if let value = normalizedText(node.value) {
            line += " value=\"\(escaped(truncated(value)))\""
        }
        if let hint = additionalText(node.hint, beyond: [node.title]) {
            line += " hint=\"\(escaped(truncated(hint)))\""
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
        let actionNames = extraActionNames(for: node)
        if !actionNames.isEmpty {
            line += " actions=\"\(actionNames.joined(separator: ","))\""
        }
        return line
    }

    private static func prioritizedBudgetedChildren(
        of node: DesktopUINode
    ) -> (children: [DesktopUINode], omittedCount: Int) {
        let children = prioritizedChildren(of: node)
        guard largeCollectionRoles.contains(node.role),
              children.count > maxLargeContainerChildren else {
            return (children, 0)
        }
        return (Array(children.prefix(maxLargeContainerChildren)), children.count - maxLargeContainerChildren)
    }

    private static func prioritizedChildren(of node: DesktopUINode) -> [DesktopUINode] {
        node.children.enumerated()
            .sorted { lhs, rhs in
                let lhsPriority = childPriority(lhs.element, in: node)
                let rhsPriority = childPriority(rhs.element, in: node)
                if lhsPriority == rhsPriority {
                    return lhs.offset < rhs.offset
                }
                return lhsPriority < rhsPriority
            }
            .map(\.element)
    }

    private static func childPriority(_ child: DesktopUINode, in parent: DesktopUINode) -> Int {
        if child.role == "AXMenuBar" {
            return 0
        }
        if parent.role == "AXMenuBar", child.role == "AXMenuBarItem" {
            return 0
        }
        if parent.role == "AXWindow", parent.isFocused, isChromeLevelControl(child) {
            return 1
        }
        if largeCollectionRoles.contains(child.role) {
            return 3
        }
        return 2
    }

    private static func isChromeLevelControl(_ node: DesktopUINode) -> Bool {
        switch node.role {
        case "AXToolbar",
             "AXButton",
             "AXPopUpButton",
             "AXMenuButton",
             "AXSearchField",
             "AXTextField",
             "AXSegmentedControl":
            return true
        default:
            return false
        }
    }

    private static func extraActionNames(for node: DesktopUINode) -> [String] {
        let nonPressActions = node.supportedActions.filter { $0 != .press }
        guard !nonPressActions.isEmpty else {
            return []
        }
        return nonPressActions.compactMap { action in
            switch action {
            case .open:
                return "open"
            case .showMenu:
                return "showMenu"
            default:
                return nil
            }
        }
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

    private static func additionalText(_ value: String?, beyond existingValues: [String?]) -> String? {
        guard let normalizedValue = normalizedText(value) else {
            return nil
        }
        let normalizedExistingValues = Set(existingValues.compactMap { normalizedText($0)?.lowercased() })
        return normalizedExistingValues.contains(normalizedValue.lowercased()) ? nil : normalizedValue
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
        if elementID == "focused" {
            return currentFocusedElement()
        }
        guard let index = elementRegistry[elementID],
              elements.indices.contains(index) else {
            return nil
        }
        return elements[index]
    }

    private func buildNodeAndAcceptedElements(
        from element: AXUIElement,
        depth: Int,
        isInMenuSubtree: Bool,
        menuAcceptedCount: inout Int
    ) -> (node: DesktopUINode, acceptedElements: [AXUIElement])? {
        let role = stringAttribute(kAXRoleAttribute as CFString, of: element) ?? "AXUnknown"
        let nodeIsInMenuSubtree = isInMenuSubtree || role == "AXMenu"
        let currentNode = buildSingleNode(from: element, role: role) ?? DesktopUINode(
            role: role,
            title: nil,
            value: nil,
            frame: nil,
            isEnabled: true,
            isFocused: false,
            children: []
        )
        let currentNodeIsListed = Self.shouldList(currentNode)
        if nodeIsInMenuSubtree, currentNodeIsListed {
            if menuAcceptedCount >= Self.maxMenuSubtreeElements {
                return nil
            }
            menuAcceptedCount += 1
        }

        let childElements = depth >= Self.maxDepth ? [] : budgetedAXChildren(of: element, role: role)
        var skippedChildCount = 0
        let traversedChildren = childElements.compactMap { childElement in
            let childTraversal = buildNodeAndAcceptedElements(
                from: childElement,
                depth: depth + 1,
                isInMenuSubtree: nodeIsInMenuSubtree,
                menuAcceptedCount: &menuAcceptedCount
            )
            if childTraversal == nil {
                skippedChildCount += 1
            }
            return childTraversal
        }
        let omittedChildCount = omittedAXChildCount(
            of: element,
            role: role,
            includedCount: childElements.count
        ) + skippedChildCount

        let node = DesktopUINode(
            role: role,
            title: currentNode.title,
            roleDescription: currentNode.roleDescription,
            value: currentNode.value,
            hint: currentNode.hint,
            frame: currentNode.frame,
            isEnabled: currentNode.isEnabled,
            isFocused: currentNode.isFocused,
            supportedActions: currentNode.supportedActions,
            omittedChildCount: omittedChildCount,
            children: traversedChildren.map(\.node)
        )

        var acceptedElements: [AXUIElement] = []
        if currentNodeIsListed {
            acceptedElements.append(element)
        }
        acceptedElements.append(contentsOf: traversedChildren.flatMap(\.acceptedElements))
        return (node, acceptedElements)
    }

    private func buildSingleNode(from element: AXUIElement, role providedRole: String? = nil) -> DesktopUINode? {
        let role = providedRole ?? stringAttribute(kAXRoleAttribute as CFString, of: element) ?? "AXUnknown"
        return DesktopUINode(
            role: role,
            title: firstTextAttribute([kAXTitleAttribute as CFString, "AXLabel" as CFString], of: element),
            roleDescription: stringAttribute(kAXRoleDescriptionAttribute as CFString, of: element),
            value: valueString(of: element),
            hint: firstTextAttribute([kAXDescriptionAttribute as CFString, kAXHelpAttribute as CFString], of: element),
            frame: frame(of: element),
            isEnabled: boolAttribute(kAXEnabledAttribute as CFString, of: element) ?? true,
            isFocused: boolAttribute(kAXFocusedAttribute as CFString, of: element) ?? false,
            supportedActions: supportedActions(of: element),
            children: []
        )
    }

    private func budgetedAXChildren(of element: AXUIElement, role: String) -> [AXUIElement] {
        let children = prioritizedAXChildren(of: element)
        if role == "AXMenuBar" {
            return children.filter { stringAttribute(kAXRoleAttribute as CFString, of: $0) == "AXMenuBarItem" }
        }
        guard Self.largeCollectionRoles.contains(role),
              children.count > Self.maxLargeContainerChildren else {
            return children
        }
        return Array(children.prefix(Self.maxLargeContainerChildren))
    }

    private func omittedAXChildCount(of element: AXUIElement, role: String, includedCount: Int) -> Int {
        guard Self.largeCollectionRoles.contains(role) else {
            return 0
        }
        let totalCount = axChildren(of: element).count
        return max(0, totalCount - includedCount)
    }

    private func prioritizedAXChildren(of element: AXUIElement) -> [AXUIElement] {
        let parentRole = stringAttribute(kAXRoleAttribute as CFString, of: element) ?? "AXUnknown"
        let parentIsFocused = boolAttribute(kAXFocusedAttribute as CFString, of: element) ?? false
        return axChildren(of: element).enumerated()
            .sorted { lhs, rhs in
                let lhsPriority = axChildPriority(lhs.element, parentRole: parentRole, parentIsFocused: parentIsFocused)
                let rhsPriority = axChildPriority(rhs.element, parentRole: parentRole, parentIsFocused: parentIsFocused)
                if lhsPriority == rhsPriority {
                    return lhs.offset < rhs.offset
                }
                return lhsPriority < rhsPriority
            }
            .map(\.element)
    }

    private func axChildPriority(
        _ child: AXUIElement,
        parentRole: String,
        parentIsFocused: Bool
    ) -> Int {
        let childRole = stringAttribute(kAXRoleAttribute as CFString, of: child) ?? "AXUnknown"
        if childRole == "AXMenuBar" {
            return 0
        }
        if parentRole == "AXMenuBar", childRole == "AXMenuBarItem" {
            return 0
        }
        if parentRole == "AXWindow", parentIsFocused,
           Self.isChromeLevelControl(DesktopUINode(
               role: childRole,
               title: nil,
               value: nil,
               frame: nil,
               isEnabled: true,
               isFocused: false,
               children: []
           )) {
            return 1
        }
        if Self.largeCollectionRoles.contains(childRole) {
            return 3
        }
        return 2
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        guard let children: [AXUIElement] = attribute(kAXChildrenAttribute as CFString, of: element) else {
            return []
        }
        return children
    }

    private func currentFocusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        return attribute(kAXFocusedUIElementAttribute as CFString, of: systemWideElement)
    }

    private func index(of target: AXUIElement, in candidates: [AXUIElement]) -> Int? {
        candidates.firstIndex { candidate in
            CFEqual(candidate, target)
        }
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

    private func supportedActions(of element: AXUIElement) -> [DesktopElementAction] {
        var actionNamesRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNamesRef) == .success,
              let actionNames = actionNamesRef as? [String] else {
            return []
        }

        let pressAction = kAXPressAction as String
        let showMenuAction = kAXShowMenuAction as String
        return actionNames.compactMap { actionName in
            if actionName == pressAction {
                return .press
            }
            if actionName == Self.axOpenAction {
                return .open
            }
            if actionName == showMenuAction {
                return .showMenu
            }
            return nil
        }
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
