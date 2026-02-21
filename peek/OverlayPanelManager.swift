//
//  OverlayPanelManager.swift
//  peek
//
//  Manages the NSPanel overlay shown when permissions are granted (MVP overlay).
//

import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// Modifiers for "hold to show" overlay. Command+Option only (no key), so typing in text fields isn't affected.
private let overlayShortcutModifiers: NSEvent.ModifierFlags = [.command, .option]

/// Manages a floating NSPanel overlay that stays on top of other windows without taking focus.
@Observable
final class OverlayPanelManager: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private var contentView: NSHostingView<OverlayPanelView>?

    /// Latest screenshot captured when shortcut was triggered; cleared on hide.
    private var currentScreenshot: NSImage?

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
            DispatchQueue.main.async { [weak self] in self?.captureAndShow() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.hide() }
        }
    }

    /// Returns the display ID of the screen that currently contains the mouse (active display), or the main screen if none.
    private static func displayIDForActiveScreen() -> CGDirectDisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen else { return nil }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return id.map { $0.uint32Value }
    }

    /// Captures the display that contains the mouse (or main display) with ScreenCaptureKit, then shows the overlay.
    private func captureAndShow() {
        let targetDisplayID = Self.displayIDForActiveScreen()

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let display = content.displays.first { $0.displayID == targetDisplayID }
                    ?? content.displays.first
                guard let display else {
                    await MainActor.run { self.showOverlayWithFallback(reason: "No display") }
                    return
                }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                var config = SCStreamConfiguration()
                config.capturesAudio = false
                config.showsCursor = true
                let scale = filter.pointPixelScale
                let rect = filter.contentRect
                config.width = Int(rect.width * CGFloat(scale))
                config.height = Int(rect.height * CGFloat(scale))

                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] cgImage, error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let cgImage {
                            self.currentScreenshot = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        } else {
                            self.currentScreenshot = nil
                        }
                        self.show()
                    }
                }
            } catch {
                await MainActor.run { self.showOverlayWithFallback(reason: "Capture failed") }
            }
        }
    }

    /// Shows the overlay without a screenshot (e.g. when capture failed); user still sees that the shortcut worked.
    private func showOverlayWithFallback(reason: String) {
        currentScreenshot = nil
        show()
    }

    func show() {
        if panel != nil { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
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

        let content = OverlayPanelView(screenshot: currentScreenshot, onClose: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: content)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hosting

        // Position in top-right of the active screen (same display we captured).
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
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
        currentScreenshot = nil
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
    var screenshot: NSImage?
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Peek Overlay")
                .font(.headline)

            if let screenshot {
                Image(nsImage: screenshot)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Text("Screenshot unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button("Close Overlay", action: onClose)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
