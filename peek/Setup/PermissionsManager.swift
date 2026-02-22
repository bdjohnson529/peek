//
//  PermissionsManager.swift
//  peek
//
//  Checks Accessibility and Screen Recording permissions.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import SwiftUI

@Observable
final class PermissionsManager {

    private(set) var hasAccessibilityPermission: Bool = false
    private(set) var hasScreenRecordingPermission: Bool = false

    var hasAllPermissions: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission
    }

    init() {
        refresh()
    }

    /// Re-check current permission state (e.g. after user returns from System Settings).
    func refresh() {
        hasAccessibilityPermission = Self.checkAccessibility()
        hasScreenRecordingPermission = Self.checkScreenRecording()

        #if DEBUG
        let execURL = Bundle.main.executableURL?.path ?? "?"
        let bundleID = Bundle.main.bundleIdentifier ?? "?"
        let pid = ProcessInfo.processInfo.processIdentifier
        print("[Peek] refresh: accessibility=\(hasAccessibilityPermission), screenRecording=\(hasScreenRecordingPermission), bundleID=\(bundleID), pid=\(pid) executablePath=\(execURL)")
        #endif
    }

    /// Check Accessibility permission (no prompt).
    private static func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Check Screen Recording permission.
    private static func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request Accessibility permission. Shows system prompt if not yet determined; otherwise opens System Settings.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    /// Request Screen Recording permission. Prompts or opens System Settings.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refresh()
    }

    /// Open System Settings to the Accessibility privacy pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to the Screen Recording privacy pane.
    func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()  // requests access so app appears in the list
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
