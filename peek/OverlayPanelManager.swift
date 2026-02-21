//
//  OverlayPanelManager.swift
//  peek
//
//  Manages the NSPanel overlay shown when permissions are granted (MVP overlay).
//

import AppKit
import Observation
import SwiftUI

/// Modifiers for "hold to show" overlay. Command+Option only (no key), so typing in text fields isn't affected.
private let overlayShortcutModifiers: NSEvent.ModifierFlags = [.command, .option]

/// Manages a floating NSPanel overlay that stays on top of other windows without taking focus.
@Observable
final class OverlayPanelManager: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private var contentView: NSHostingView<OverlayPanelView>?

    private var localShortcutMonitor: Any?
    private var globalShortcutMonitor: Any?

    func startShortcutMonitoring() {
        stopShortcutMonitoring()

        let mask: NSEvent.EventTypeMask = .flagsChanged

        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleShortcutEvent(event)
            return event
        }

        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleShortcutEvent(event)
        }
    }

    func stopShortcutMonitoring() {
        if let local = localShortcutMonitor {
            NSEvent.removeMonitor(local)
            localShortcutMonitor = nil
        }
        if let global = globalShortcutMonitor {
            NSEvent.removeMonitor(global)
            globalShortcutMonitor = nil
        }
    }

    private func handleShortcutEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let bothHeld = modifiers.contains(overlayShortcutModifiers)

        if bothHeld {
            DispatchQueue.main.async { [weak self] in self?.show() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.hide() }
        }
    }

    func show() {
        if panel != nil { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.nonactivatingPanel, .titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Peek"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // Use a level above the menu bar so the overlay can sit in the top-right over it.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let content = OverlayPanelView(onClose: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: content)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hosting

        // Position in top-right of screen, as far up and right as possible (over menu bar).
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? panel.frame
        let panelFrame = panel.frame
        let x = screenFrame.maxX - panelFrame.width
        let y = screenFrame.maxY - panelFrame.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.orderFrontRegardless()

        self.panel = panel
        self.contentView = hosting
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        contentView = nil
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSPanel, window === panel else { return }
        panel = nil
        contentView = nil
    }
}

/// SwiftUI content for the overlay panel (MVP placeholder).
struct OverlayPanelView: View {
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Peek Overlay")
                .font(.headline)
            Text("Overlay is active.")
                .foregroundStyle(.secondary)
            Button("Close Overlay", action: onClose)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
