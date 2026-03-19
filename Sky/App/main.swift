import AppKit

/// Application entry point. Creates the NSApplication and sets AppDelegate as the delegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
