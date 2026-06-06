import AppKit

if CommandLine.arguments.contains("--selftest") { SelfTest.run() }

// Menu-bar agent entry point. No storyboard, no Dock icon (LSUIElement).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
