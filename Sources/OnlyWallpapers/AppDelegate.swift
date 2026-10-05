import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Retained for the process lifetime; SIGINT terminates the app cleanly.
    private var sigintSource: DispatchSourceSignal?

    // Spike: activity token and windows kept alive for the process lifetime.
    // AnyObject is used so this file does not reference the spike-only window type.
    private var spikeActivity: NSObjectProtocol?
    private var spikeWindows: [AnyObject] = []

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

        let env = ProcessInfo.processInfo.environment
        let owWebSpike = env["OW_WEBSPIKE"] == "1"
        let owSpikeAndWeb = env["OW_SPIKE"] == "1" && owWebSpike

        if owSpikeAndWeb {
            FileHandle.standardOutput.write(Data("OW_WEBSPIKE FINDING: OW_SPIKE and OW_WEBSPIKE both set, refusing\n".utf8))
            return
        }

        if owWebSpike {
            FileHandle.standardOutput.write(Data("OW_WEBSPIKE SCREENS count=\(NSScreen.screens.count)\n".utf8))

            if env["OW_WEBSPIKE_ACTIVITY"] == "1" {
                spikeActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep],
                    reason: "ow-webspike"
                )
                FileHandle.standardOutput.write(Data("OW_WEBSPIKE activity=held\n".utf8))
            }

            let webSpikeDir: URL
            let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            if let envDir = env["OW_WEBSPIKE_DIR"] {
                webSpikeDir = URL(fileURLWithPath: envDir, relativeTo: cwdURL).standardizedFileURL
            } else if let wallpaperDir = env["WALLPAPER_WEB_DIR"] {
                let candidate = URL(fileURLWithPath: wallpaperDir, relativeTo: cwdURL).standardizedFileURL
                let hasIndex = FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.html").path)
                let hasMp4 = FileManager.default.fileExists(atPath: candidate.appendingPathComponent("bg.mp4").path)
                if hasIndex && hasMp4 {
                    webSpikeDir = candidate
                } else {
                    webSpikeDir = URL(fileURLWithPath: ".build/webspike", relativeTo: cwdURL).standardizedFileURL
                }
            } else {
                webSpikeDir = URL(fileURLWithPath: ".build/webspike", relativeTo: cwdURL).standardizedFileURL
            }

            let filtered = env["OW_WEBSPIKE_NOFILTER"] != "1"
            let clearMode = env["OW_WEBSPIKE_CLEAR"] == "1"
            let screens = NSScreen.screens
            if screens.isEmpty {
                FileHandle.standardOutput.write(Data("OW_WEBSPIKE FINDING: no screens\n".utf8))
            } else {
                for screen in screens {
                    let ctrl = WebSpikeController(screen: screen, webDir: webSpikeDir, filtered: filtered, clearMode: clearMode)
                    ctrl.window.orderFrontRegardless()
                    spikeWindows.append(ctrl)
                }
            }
        }

        if ProcessInfo.processInfo.environment["OW_SPIKE"] == "1" {
            spikeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "ow-spike"
            )
            FileHandle.standardOutput.write(Data("OW_SPIKE activity=held\n".utf8))
            let screens = NSScreen.screens
            FileHandle.standardOutput.write(Data("OW_SPIKE SCREENS count=\(screens.count)\n".utf8))
            if screens.isEmpty {
                FileHandle.standardOutput.write(Data("OW_SPIKE FINDING: no screens\n".utf8))
            } else {
                for screen in screens {
                    let w = makeSpikeWindowAndShow(for: screen)
                    spikeWindows.append(w)
                }
            }
        }
    }
}
