//
//  SetupView.swift
//  peek
//
//  Permissions setup and app settings (also used for Peek → Settings…).
//

import AppKit
import SwiftUI

struct SetupView: View {
    var permissions: PermissionsManager
    /// When false, skips bringing the Setup window to front (e.g. when shown in Settings).
    var bringWindowToFront: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Setup Required")
                .font(.title2.bold())

            Text("Peek needs the following permissions to work. Grant them in System Settings, then return here and click **Check Again**.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(
                    title: "Accessibility",
                    granted: permissions.hasAccessibilityPermission,
                    action: { permissions.openAccessibilitySettings() }
                )
                PermissionRow(
                    title: "Screen Recording",
                    granted: permissions.hasScreenRecordingPermission,
                    action: { permissions.openScreenRecordingSettings() }
                )
            }

            HStack {
                Button("Check Again") {
                    permissions.refresh()
                }
                .buttonStyle(.borderedProminent)

                if permissions.hasAllPermissions {
                    Text("All set!")
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 360, minHeight: 320)
        .onAppear {
            guard bringWindowToFront else { return }
            DispatchQueue.main.async {
                let window = NSApplication.shared.windows
                    .first { $0.identifier?.rawValue == "setup" }
                    ?? NSApplication.shared.windows.first { $0.title == "Setup" }
                window?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
                .font(.body)
            Spacer()
            if !granted {
                Button("Open System Settings", action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SetupView(permissions: PermissionsManager())
        .frame(width: 360, height: 360)
}
