import AppKit

if ProcessInfo.processInfo.environment["OW_SELFTEST"] == "1" {
    SelfTest.runAll()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
