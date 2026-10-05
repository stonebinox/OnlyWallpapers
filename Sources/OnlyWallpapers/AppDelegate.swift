import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Retained for the process lifetime; SIGINT terminates the app cleanly.
    private var sigintSource: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let ok = NSApp.setActivationPolicy(.accessory)
        precondition(ok, "failed to set .accessory activation policy")

        // Install SIGINT handler before announcing readiness so no window exists
        // where the default disposition (exit 130) can fire.
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigintSource = src
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sample policy after AppKit completes its launch sequence so the value
        // reflects the final runtime state, not the in-flight state.
        let policy = NSApp.activationPolicy() == .accessory ? "accessory" : "OTHER:\(NSApp.activationPolicy().rawValue)"
        let pid = ProcessInfo.processInfo.processIdentifier
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_READY policy=\(policy) pid=\(pid)\n".utf8))
    }
}
