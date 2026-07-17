//
//  AXFocusProbe.swift
//  Lorelei
//
//  DEBUG-only diagnostic behind lorelei://ax-probe: reports the FRONTMOST
//  app's focused element's AX capabilities to the diag log so replacement
//  strategies can be chosen per app. Strictly read-only (settability is
//  queried via AXUIElementIsAttributeSettable, never by setting). Logs
//  roles, booleans, and lengths - never field content.
//

#if DEBUG
import AppKit
import ApplicationServices
import Foundation

@MainActor
enum AXFocusProbe {
    static func runAndLog() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            LoreleiDiagLog.log("axProbe: no frontmost app")
            return
        }
        let pid = app.processIdentifier
        LoreleiDiagLog.log(
            "axProbe: app=\(app.localizedName ?? "?") bundle=\(app.bundleIdentifier ?? "?") pid=\(pid)"
        )

        let appElement = AXUIElementCreateApplication(pid)
        var focusedObject: AnyObject?
        let focusedStatus = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedObject)
        guard focusedStatus == .success,
              let focusedObject,
              CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            LoreleiDiagLog.log("axProbe: focusedElement UNREADABLE status=\(focusedStatus.rawValue)")
            return
        }
        let element = focusedObject as! AXUIElement

        LoreleiDiagLog.log("axProbe: role=\(stringAttribute(element, kAXRoleAttribute) ?? "nil") subrole=\(stringAttribute(element, kAXSubroleAttribute) ?? "nil")")

        if let value = stringAttribute(element, kAXValueAttribute) {
            LoreleiDiagLog.log("axProbe: AXValue readable=true length=\((value as NSString).length)")
        } else {
            LoreleiDiagLog.log("axProbe: AXValue readable=false")
        }

        if let selected = stringAttribute(element, kAXSelectedTextAttribute) {
            LoreleiDiagLog.log("axProbe: AXSelectedText readable=true length=\((selected as NSString).length)")
        } else {
            LoreleiDiagLog.log("axProbe: AXSelectedText readable=false")
        }

        var rangeObject: AnyObject?
        if AXUIElementCopyAttributeValue(
               element, kAXSelectedTextRangeAttribute as CFString, &rangeObject) == .success,
           let rangeObject,
           CFGetTypeID(rangeObject) == AXValueGetTypeID() {
            var cfRange = CFRange()
            if AXValueGetValue(rangeObject as! AXValue, .cfRange, &cfRange) {
                LoreleiDiagLog.log("axProbe: AXSelectedTextRange readable=true location=\(cfRange.location) length=\(cfRange.length)")
            } else {
                LoreleiDiagLog.log("axProbe: AXSelectedTextRange readable=true (non-CFRange payload)")
            }
        } else {
            LoreleiDiagLog.log("axProbe: AXSelectedTextRange readable=false")
        }

        logSettable(element, kAXSelectedTextRangeAttribute)
        logSettable(element, kAXSelectedTextAttribute)
        logSettable(element, kAXValueAttribute)

        var number: AnyObject?
        if AXUIElementCopyAttributeValue(
               element, kAXNumberOfCharactersAttribute as CFString, &number) == .success,
           let count = number as? Int {
            LoreleiDiagLog.log("axProbe: AXNumberOfCharacters=\(count)")
        } else {
            LoreleiDiagLog.log("axProbe: AXNumberOfCharacters unreadable")
        }

        var parameterized: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(element, &parameterized) == .success,
           let names = parameterized as? [String] {
            let hasStringForRange = names.contains(kAXStringForRangeParameterizedAttribute as String)
            LoreleiDiagLog.log("axProbe: parameterized stringForRange=\(hasStringForRange) count=\(names.count)")
        } else {
            LoreleiDiagLog.log("axProbe: parameterized attributes unreadable")
        }

        LoreleiDiagLog.log("axProbe: done")
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var object: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &object) == .success else {
            return nil
        }
        return object as? String
    }

    private static func logSettable(_ element: AXUIElement, _ attribute: String) {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        LoreleiDiagLog.log(
            "axProbe: settable \(attribute)=\(status == .success ? String(describing: settable.boolValue) : "query-failed(\(status.rawValue))")"
        )
    }
}
#endif
