//
//  peekApp.swift
//  peek
//
//  Menu bar app: shows Setup when permissions are missing, NSPanel overlay when granted.
//

import SwiftUI

@main
struct peekApp: App {
    @State private var permissions = PermissionsManager()
    @State private var overlayManager = OverlayPanelManager()

    init() {
        #if DEBUG
        OpenAIVisionClient.debugLogAPIKey()
        #endif
    }

    var body: some Scene {
        MenuBarExtra("Peek", systemImage: "eye") {
            MenuBarContentView(permissions: permissions, overlayManager: overlayManager)
        }
        .menuBarExtraStyle(.menu)

        Window("Setup", id: "setup") {
            SetupView(permissions: permissions)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 400, height: 300)
        .windowResizability(.contentSize)

        Settings {
            SetupView(permissions: permissions, bringWindowToFront: false)
        }
    }
}
