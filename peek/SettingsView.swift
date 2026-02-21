//
//  SettingsView.swift
//  peek
//
//  App settings (Peek → Settings…). API key is set in the Run scheme’s environment variables.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("API key is set in the Run scheme: Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables → OPENAI_API_KEY.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } header: {
                Text("API")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, minHeight: 100)
    }
}
