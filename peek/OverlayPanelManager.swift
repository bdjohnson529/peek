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

    /// Latest screenshot; persisted when overlay is hidden so it can reappear.
    private var currentScreenshot: NSImage?

    /// Capture context for mapping LLM normalized bbox to screen coordinates. Set when capture succeeds.
    private(set) var captureContentRect: CGRect?
    private(set) var captureScale: CGFloat = 1

    /// Last highlight shown; persisted so we can re-show it when overlay reappears.
    private var lastHighlightScreenRect: CGRect?
    private var lastHighlightDisplayFrame: CGRect?

    private let highlightManager = HighlightOverlayManager()

    /// Feedback flow state for the overlay UI.
    enum FeedbackState: Sendable {
        case idle
        case loading
        case success(answer: String)
        case failure(message: String)
    }
    private(set) var feedbackState: FeedbackState = .idle

    private var localShortcutMonitor: Any?
    private var globalShortcutMonitor: Any?

    /// True when the shortcut was held during the previous flagsChanged event.
    private var shortcutWasHeld = false
    /// True if we hid the overlay during this hold (so we don’t show again on release).
    private var didHideDuringHold = false

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
            // Shortcut pressed: dismiss overlay if visible (user pressing again to close).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.panel != nil {
                    self.hide()
                    self.didHideDuringHold = true
                }
                self.shortcutWasHeld = true
            }
        } else {
            // Shortcut released: show overlay only if we didn’t just dismiss it (so user can type).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.shortcutWasHeld, !self.didHideDuringHold {
                    if self.currentScreenshot != nil {
                        self.showExisting()
                    } else {
                        self.captureAndShow()
                    }
                }
                self.shortcutWasHeld = false
                self.didHideDuringHold = false
            }
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
                        self.captureContentRect = rect
                        self.captureScale = CGFloat(scale)
                        if let cgImage {
                            self.currentScreenshot = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                            self.lastHighlightScreenRect = nil
                            self.lastHighlightDisplayFrame = nil
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
        captureContentRect = nil
        show()
    }

    /// Shows the overlay using persisted state (screenshot, answer, highlight) without re-capturing.
    private func showExisting() {
        show()
    }

    func show() {
        if panel != nil { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
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

        let content = OverlayPanelView(manager: self, screenshot: currentScreenshot, onClose: { [weak self] in self?.hide() })
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

        // Restore persisted highlight on next run loop so the overlay panel is fully visible first.
        let rect = lastHighlightScreenRect
        let frame = lastHighlightDisplayFrame
        if rect != nil, frame != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let rect, let frame {
                    self.highlightManager.show(screenRect: rect, displayFrame: frame, autoDismissAfterSeconds: 3600)
                }
            }
        }
    }

    func hide() {
        highlightManager.hide()
        panel?.orderOut(nil)
        panel = nil
        contentView = nil
        // Keep currentScreenshot, captureContentRect, feedbackState, lastHighlight* so they persist and reappear on next show.
    }

    /// Run the feedback flow: call LLM with current screenshot and question; show highlight if bbox returned.
    func submitFeedback(question: String) async {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let image = currentScreenshot else {
            await MainActor.run { feedbackState = .failure(message: "No screenshot. Show the overlay with the shortcut first.") }
            return
        }
        await MainActor.run { feedbackState = .loading }
        do {
            let response = try await LLMVisionService.ask(image: image, question: question)
            await MainActor.run {
                feedbackState = .success(answer: response.answer)
                if let bbox = response.boundingBox,
                   let contentRect = captureContentRect {
                    let rect = screenRect(
                        forNormalizedBbox: bbox.x, y: bbox.y, width: bbox.width, height: bbox.height,
                        contentRect: contentRect
                    )
                    lastHighlightScreenRect = rect
                    lastHighlightDisplayFrame = contentRect
                    highlightManager.show(screenRect: rect, displayFrame: contentRect, autoDismissAfterSeconds: 3600)
                }
            }
        } catch {
            await MainActor.run {
                feedbackState = .failure(message: error.localizedDescription)
            }
        }
    }

    func dismissHighlight() {
        highlightManager.hide()
    }

    var isHighlightVisible: Bool {
        highlightManager.isVisible
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSPanel, window === panel else { return }
        hide()
    }
}

/// SwiftUI content for the overlay panel: screenshot, feedback text field, Ask, and result.
struct OverlayPanelView: View {
    var manager: OverlayPanelManager
    var screenshot: NSImage?
    var onClose: () -> Void

    @State private var questionText = ""

    var body: some View {
        VStack(spacing: 12) {
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

            Group {
                TextField("Ask about this screen...", text: $questionText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2 ... 4)
                    .disabled(loading)

                HStack {
                    Button("Ask") {
                        Task { await manager.submitFeedback(question: questionText) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)

                    if manager.isHighlightVisible {
                        Button("Dismiss highlight") {
                            manager.dismissHighlight()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if loading {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                switch manager.feedbackState {
                case .idle:
                    EmptyView()
                case .loading:
                    EmptyView()
                case .success(let answer):
                    Text(answer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                case .failure(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            Button("Close Overlay", action: onClose)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var loading: Bool {
        if case .loading = manager.feedbackState { return true }
        return false
    }
}
