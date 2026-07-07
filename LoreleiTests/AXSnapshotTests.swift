//
//  AXSnapshotTests.swift
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
struct AXSnapshotTests {

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
}
