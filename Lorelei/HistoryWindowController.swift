//
//  HistoryWindowController.swift
//  Lorelei
//
//  Owns the fixed-size conversation history viewer window.
//

import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private let store: ConversationHistoryStore
    private var window: NSWindow?

    init(store: ConversationHistoryStore = ConversationHistoryStore()) {
        self.store = store
        super.init()
    }

    func show() {
        let historyWindow = window ?? makeWindow()
        window = historyWindow

        // LSUIElement keeps Lorelei dockless by default; regular activation
        // gives the history window standard app-menu and key-window behavior.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        // Fixed-size AppKit window with a plain NSHostingView.
        // Do NOT use NSHostingController, WindowFittingHostingView, or any
        // SwiftUI-driven window sizing - that machinery crashes on this OS
        // (plan 033/034 crash doctrine). Leave hosting-view size options empty.
        let hostingView = NSHostingView(
            rootView: HistoryView(store: store)
        )
        hostingView.sizingOptions = []

        let historyWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        historyWindow.contentView = hostingView
        historyWindow.setContentSize(NSSize(width: 560, height: 480))
        historyWindow.title = "Lorelei History"
        historyWindow.isReleasedWhenClosed = false
        historyWindow.isMovableByWindowBackground = true
        historyWindow.delegate = self
        historyWindow.center()
        return historyWindow
    }
}

struct HistoryView: View {
    let store: ConversationHistoryStore

    @State private var records: [ConversationHistoryRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            if records.isEmpty {
                Spacer()
                Text("No conversation history yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                            historyRow(record)
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Clear History") {
                    deferredAction {
                        try? store.clear()
                        reload()
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func historyRow(_ record: ConversationHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(roleLabel(for: record.role))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(record.ts)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }

            if record.role == "user" {
                HStack {
                    Spacer(minLength: 34)
                    Text(record.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                }
            } else {
                Text(record.text)
                    .font(.system(size: 12, weight: .light, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func roleLabel(for role: String) -> String {
        switch role {
        case "user":
            return "You"
        case "assistant":
            return "Lorelei"
        default:
            return role
        }
    }

    private func reload() {
        records = (try? store.readAll()) ?? []
    }
}
