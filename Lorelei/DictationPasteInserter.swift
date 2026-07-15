//
//  DictationPasteInserter.swift
//  Lorelei
//
//  Inserts dictation text the way commercial dictation apps do: put Unicode
//  on the pasteboard, activate the target app, post Cmd+V, then restore the
//  previous clipboard. Cmd+V is a single command chord - not per-character
//  key synthesis - so Japanese IME is not broken the way typed keystrokes are.
//

import AppKit
import ApplicationServices
import Foundation

enum DictationInsertionOutcome: Equatable, Sendable {
    case inserted
    /// Paste was skipped or could not be posted. Transcript remains on the pasteboard.
    case leftOnClipboard
}

protocol DictationTextInserting: AnyObject {
    func insert(_ text: String, targetProcessID: pid_t?) async -> DictationInsertionOutcome
}

/// Pure pasteboard snapshot helpers (unit-tested).
enum DictationPasteboardSnapshot {
    static func capture(from pasteboard: NSPasteboard = .general) -> [[String: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var encoded: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    encoded[type.rawValue] = data
                }
            }
            return encoded
        }
    }

    static func restore(
        _ snapshot: [[String: Data]],
        to pasteboard: NSPasteboard = .general
    ) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }

        let objects: [NSPasteboardItem] = snapshot.map { encoded in
            let item = NSPasteboardItem()
            for (rawType, data) in encoded {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        pasteboard.writeObjects(objects)
    }
}

/// Decides whether Cmd+V is likely to land in an editable surface.
/// Finder-style roles leave the transcript on the clipboard instead of
/// posting paste and restoring (which would discard the spoken text).
enum DictationPasteTargetHeuristic {
    static let clearlyNonEditableRoles: Set<String> = [
        "AXApplication",
        "AXWindow",
        "AXImage",
        "AXToolbar",
        "AXMenuBar",
        "AXMenu",
        "AXMenuItem",
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXSlider",
        "AXTable",
        "AXOutline",
        "AXList",
        "AXBrowser",
        "AXGrid",
        "AXSplitter",
        "AXTabGroup",
        "AXProgressIndicator",
        "AXBusyIndicator",
        "AXColorWell",
        "AXDockItem"
    ]

    static let clearlyEditableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        "AXWebArea",
        "AXScrollArea"
    ]

    static func shouldAttemptPaste(
        role: String?,
        selectedTextSettable: Bool,
        valueSettable: Bool,
        hasFocusedElement: Bool
    ) -> Bool {
        // No AX focus (common for some Electron surfaces) - still paste.
        guard hasFocusedElement else { return true }
        if selectedTextSettable || valueSettable { return true }
        if let role, clearlyEditableRoles.contains(role) { return true }
        if let role, clearlyNonEditableRoles.contains(role) { return false }
        // Unknown / AXGroup / custom roles: attempt paste (Cursor, Chrome).
        return true
    }
}

@MainActor
final class DictationPasteInserter: DictationTextInserting {
    private let pasteboard: NSPasteboard
    private let activateProcess: (pid_t) -> Bool
    private let postCommandV: () -> Bool
    private let shouldAttemptPaste: () -> Bool
    private let activateSettlingDelay: Duration
    private let pasteSettlingDelay: Duration

    init(
        pasteboard: NSPasteboard = .general,
        activateProcess: @escaping (pid_t) -> Bool = { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                return false
            }
            return app.activate(options: [.activateIgnoringOtherApps])
        },
        postCommandV: (() -> Bool)? = nil,
        shouldAttemptPaste: (() -> Bool)? = nil,
        activateSettlingDelay: Duration = .milliseconds(80),
        pasteSettlingDelay: Duration = .milliseconds(150)
    ) {
        self.pasteboard = pasteboard
        self.activateProcess = activateProcess
        self.postCommandV = postCommandV ?? { DictationPasteInserter.postCommandVEvent() }
        self.shouldAttemptPaste = shouldAttemptPaste ?? {
            DictationPasteInserter.focusedElementLooksPasteable()
        }
        self.activateSettlingDelay = activateSettlingDelay
        self.pasteSettlingDelay = pasteSettlingDelay
    }

    func insert(_ text: String, targetProcessID: pid_t?) async -> DictationInsertionOutcome {
        let previous = DictationPasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        LoreleiDiagLog.log(
            "systemDictation: pasteboard loaded chars=\(text.count) targetPID=\(targetProcessID.map(String.init) ?? "nil")"
        )

        guard shouldAttemptPaste() else {
            LoreleiDiagLog.log("systemDictation: non-editable focus → leave clipboard")
            return .leftOnClipboard
        }

        if let targetProcessID {
            let activated = activateProcess(targetProcessID)
            LoreleiDiagLog.log("systemDictation: activate target ok=\(activated)")
            try? await Task.sleep(for: activateSettlingDelay)
        }

        guard postCommandV() else {
            LoreleiDiagLog.log("systemDictation: Cmd+V post failed; leaving clipboard")
            return .leftOnClipboard
        }

        LoreleiDiagLog.log("systemDictation: Cmd+V posted")
        try? await Task.sleep(for: pasteSettlingDelay)
        DictationPasteboardSnapshot.restore(previous, to: pasteboard)
        LoreleiDiagLog.log("systemDictation: clipboard restored")
        return .inserted
    }

    /// Posts ⌘V through the HID event tap. Accessibility permission is required.
    private static func postCommandVEvent() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }
        // kVK_ANSI_V
        let keyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func focusedElementLooksPasteable() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: AnyObject?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard focusedError == .success,
              let focusedObject,
              CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            return DictationPasteTargetHeuristic.shouldAttemptPaste(
                role: nil,
                selectedTextSettable: false,
                valueSettable: false,
                hasFocusedElement: false
            )
        }

        let focusedElement = focusedObject as! AXUIElement
        let role = stringAttribute(kAXRoleAttribute as CFString, of: focusedElement)
        return DictationPasteTargetHeuristic.shouldAttemptPaste(
            role: role,
            selectedTextSettable: isAttributeSettable(
                kAXSelectedTextAttribute as CFString,
                of: focusedElement
            ),
            valueSettable: isAttributeSettable(
                kAXValueAttribute as CFString,
                of: focusedElement
            ),
            hasFocusedElement: true
        )
    }

    private static func isAttributeSettable(_ attribute: CFString, of element: AXUIElement) -> Bool {
        var isSettable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return error == .success && isSettable.boolValue
    }

    private static func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var object: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute, &object)
        guard error == .success, let object else { return nil }
        return object as? String
    }
}
