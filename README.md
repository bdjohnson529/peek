# Peek

A macOS menu bar app that shows a floating overlay when you need it.

## What it does

- **Menu bar** — Click the Peek (eye) icon in the menu bar to open the menu.
- **Setup** — If Accessibility or Screen Recording permissions aren’t granted, the app opens a Setup window with links to System Settings. After enabling the permissions, use **Check Again** and then **Show Overlay** from the menu.
- **Overlay** — When permissions are granted, you can show or hide a floating panel that stays on top of other windows without stealing focus. Toggle it from the menu or close it from the panel.

## Requirements

- macOS (SwiftUI, AppKit)
- **Accessibility** and **Screen Recording** permissions (required for the overlay to work)

## Build and run

Open `peek.xcodeproj` in Xcode and run (⌘R).
