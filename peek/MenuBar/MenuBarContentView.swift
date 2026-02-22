//
//  MenuBarContentView.swift
//  peek
//
//  Menu bar menu and logic: open Setup or show overlay based on permissions.
//

import SwiftUI

struct MenuBarContentView: View {
    var permissions: PermissionsManager
    var overlayManager: OverlayPanelManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if !permissions.hasAllPermissions {
                Button("Open Setup...") {
                    permissions.refresh()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "setup")
                }
            }

            if permissions.hasAllPermissions {
                Button(overlayManager.isVisible ? "Hide Overlay" : "Show Overlay") {
                    if overlayManager.isVisible {
                        overlayManager.hide()
                    } else {
                        overlayManager.show()
                    }
                }
                .keyboardShortcut(" ", modifiers: .option)
                .help("Hold ⌥ Space to show overlay; release to hide")
            }

            Divider()

            Button("Quit Peek") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .onAppear {
            permissions.refresh()
            if permissions.hasAllPermissions {
                overlayManager.startShortcutMonitoring()
                overlayManager.show()
            }
        }
    }
}
