//
//  OverlayPanelManager.swift
//  peek
//
//  Manages the NSPanel overlay shown when permissions are granted (MVP overlay).
//

import AppKit
import Observation
import SwiftUI

/// Manages a floating NSPanel overlay that stays on top of other windows without taking focus.
@Observable
final class OverlayPanelManager {

    private var panel: NSPanel?
    private var contentView: NSHostingView<OverlayPanelView>?

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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = OverlayPanelView(onClose: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: content)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hosting

        panel.center()
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
