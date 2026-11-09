import AppKit

// A menu bar app: no Dock icon, no main window. Info.plist says so for the
// bundle; this says so for `swift run`.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
