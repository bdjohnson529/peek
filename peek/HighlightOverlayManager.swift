//
//  HighlightOverlayManager.swift
//  peek
//
//  Full-screen transparent overlay that draws a bounding box on the display
//  (e.g. where the user should click). Uses the same display as the capture.
//

import AppKit
import CoreGraphics

/// Converts a pixel bounding box from the LLM (in image pixel space) to screen coordinates.
/// Maps proportionally from (imagePixelWidth x imagePixelHeight) to displayFrame (points).
/// Image is top-left origin; macOS screen Y increases upward.
func screenRect(
    forPixelBbox x: Double, y: Double, width: Double, height: Double,
    imagePixelWidth: Int, imagePixelHeight: Int,
    displayFrame: CGRect
) -> CGRect {
    guard imagePixelWidth > 0, imagePixelHeight > 0 else {
        return .zero
    }
    let scaleX = displayFrame.width / CGFloat(imagePixelWidth)
    let scaleY = displayFrame.height / CGFloat(imagePixelHeight)
    let pointX = CGFloat(x) * scaleX
    let pointY = CGFloat(y) * scaleY
    let pointW = CGFloat(width) * scaleX
    let pointH = CGFloat(height) * scaleY
    let screenX = displayFrame.minX + pointX
    let screenY = displayFrame.maxY - (pointY + pointH)
    return CGRect(x: screenX, y: screenY, width: pointW, height: pointH)
}

/// Manages a single full-screen transparent window that draws one rectangle (bounding box).
final class HighlightOverlayManager {

    private var window: NSWindow?
    private var highlightRect: CGRect = .zero
    private var displayFrame: CGRect = .zero
    private var dismissWorkItem: DispatchWorkItem?

    /// Shows a highlight rectangle on the given display. `screenRect` is in screen coordinates;
    /// `displayFrame` is the frame of the display (in screen coords) so the window is positioned correctly.
    func show(screenRect: CGRect, displayFrame: CGRect, autoDismissAfterSeconds: TimeInterval = 10) {
        hide()

        let panel = NSPanel(
            contentRect: displayFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        // Match overlay panel: stay visible when user switches apps; only hide via hotkey.
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true

        // Convert screen rect to window (content) coordinates.
        let rectInWindow = CGRect(
            x: screenRect.minX - displayFrame.minX,
            y: screenRect.minY - displayFrame.minY,
            width: screenRect.width,
            height: screenRect.height
        )
        let highlightView = HighlightRectView(rect: rectInWindow)
        highlightView.frame = NSRect(origin: .zero, size: displayFrame.size)
        highlightView.autoresizingMask = [.width, .height]
        panel.contentView = highlightView

        panel.orderFrontRegardless()

        self.window = panel
        self.highlightRect = screenRect
        self.displayFrame = displayFrame

        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.hide() }
        }
        self.dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissAfterSeconds, execute: work)
    }

    func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        window?.orderOut(nil)
        window = nil
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }
}

/// Draws a single rectangle (stroke + light fill) in its bounds.
private final class HighlightRectView: NSView {

    let rect: CGRect

    init(rect: CGRect) {
        self.rect = rect
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemOrange.cgColor)
        ctx.setLineWidth(4)
        ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.15).cgColor)
        ctx.addRect(rect)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }
}
