import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigintSource: DispatchSourceSignal?
    private var wallpaperController: WallpaperController?
    private var moodController: MoodController?
    private var sigUSR1Source: DispatchSourceSignal?
    private var sigUSR2Source: DispatchSourceSignal?
    private var spikeActivity: NSObjectProtocol?
    private var webSpikeControllers: [AnyObject] = []
    private var statusItemController: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if NSApp.activationPolicy() != .accessory {
            let ok = NSApp.setActivationPolicy(.accessory)
            precondition(ok, "failed to set .accessory activation policy")
        }

        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigintSource = src
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let policy = NSApp.activationPolicy() == .accessory ? "accessory" : "OTHER:\(NSApp.activationPolicy().rawValue)"
        let pid = ProcessInfo.processInfo.processIdentifier
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_READY policy=\(policy) pid=\(pid)\n".utf8))

        let env = ProcessInfo.processInfo.environment
        let owWebSpike = env["OW_WEBSPIKE"] == "1"

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
                    webSpikeControllers.append(ctrl)
                }
            }
        } else {
            let wallpaperWebDir = env["WALLPAPER_WEB_DIR"]
            if wallpaperWebDir == nil || (wallpaperWebDir?.isEmpty == true) {
                if let bundleIdx = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "web") {
                    let bundleWebDir = bundleIdx.deletingLastPathComponent()
                    AppStorageManager.seedWebDirIfNeeded(fromBundleWebDir: bundleWebDir)
                } else {
                    FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_SEED status=fail source=bundle reason=no-bundle-index\n".utf8))
                    AppStorageManager.seedFailed = true
                }
            }

            // Resolve once to get the actual source for picker state.
            // seedFailed=false is not sufficient: a malformed tree (dir named wallpaper.js,
            // unreadable file) passes seeding but the resolver falls back to bundle.
            let resolved = WebDirectoryResolver.resolve()
            let pickerEnabled: Bool
            if resolved.source == "appstore" {
                let assetsDir = AppStorageManager.appSupportRoot()
                    .appendingPathComponent("web")
                    .appendingPathComponent("assets")
                pickerEnabled = FileManager.default.isWritableFile(atPath: assetsDir.path)
            } else {
                pickerEnabled = false
            }
            let pickerSource = resolved.source

            let controller = WallpaperController()
            controller.initialBuild()
            self.wallpaperController = controller

            if env["OW_FAKE_SCREENS_FILE"] != nil {
                signal(SIGUSR1, SIG_IGN)
                let usr1Src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
                usr1Src.setEventHandler {
                    NotificationCenter.default.post(
                        name: NSApplication.didChangeScreenParametersNotification,
                        object: NSApp)
                }
                usr1Src.resume()
                self.sigUSR1Source = usr1Src
            } else if env["OW_REBUILD_TEST"] == "1" {
                signal(SIGUSR1, SIG_IGN)
                let usr1Src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
                usr1Src.setEventHandler { [weak controller] in
                    controller?.forceRecommit()
                }
                usr1Src.resume()
                self.sigUSR1Source = usr1Src
            }

            let mood = MoodController()
            mood.onMoodUpdate = { [weak controller] params in
                controller?.applyMoodToAll(params)
            }
            mood.onStormUpdate = { [weak controller] active in
                controller?.applyStormToAll(active)
            }
            // FIX 1: wire onMoodUpdate before calling start() so the first broadcast is not lost.
            moodController = mood

            if env["OW_WGT_STORM_TOGGLE_TEST"] == "1" {
                signal(SIGUSR2, SIG_IGN)
                let usr2Src = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
                usr2Src.setEventHandler { [weak controller] in
                    controller?.forceStormOff()
                }
                usr2Src.resume()
                self.sigUSR2Source = usr2Src
            } else if env["OW_FRAMING_TEST"] == "1" {
                signal(SIGUSR2, SIG_IGN)
                let usr2Src = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
                usr2Src.setEventHandler { [weak controller] in
                    controller?.zoomBy(0.1)
                }
                usr2Src.resume()
                self.sigUSR2Source = usr2Src
            } else if env["OW_VIDEO_TEST"] == "1" {
                signal(SIGUSR2, SIG_IGN)
                let usr2Src = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
                // OW_VIDEO_TEST_SRC_FILE: path to a file whose content is the video path to copy.
                // Read at signal time so the gate can update the file between two SIGUSR2 sends.
                let testSrcFilePath = env["OW_VIDEO_TEST_SRC_FILE"]
                usr2Src.setEventHandler { [weak controller] in
                    if let sfp = testSrcFilePath, !sfp.isEmpty,
                       let srcPath = try? String(contentsOfFile: sfp, encoding: .utf8)
                           .trimmingCharacters(in: .whitespacesAndNewlines),
                       !srcPath.isEmpty {
                        let destDir = AppStorageManager.appSupportRoot()
                            .appendingPathComponent("web")
                            .appendingPathComponent("assets")
                        let srcURL = URL(fileURLWithPath: srcPath)
                        Task.detached(priority: .userInitiated) {
                            let result = copyVideoFile(from: srcURL, toAssetsDir: destDir)
                            await MainActor.run {
                                switch result {
                                case .success:
                                    controller?.reloadVideo()
                                case .failure(let err):
                                    FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_VIDEO copy-hook=fail error=\(err.localizedDescription)\n".utf8))
                                }
                            }
                        }
                    } else {
                        controller?.reloadVideo()
                    }
                }
                usr2Src.resume()
                self.sigUSR2Source = usr2Src
            } else if env["OW_MOOD_TEST"] == "1" {
                signal(SIGUSR2, SIG_IGN)
                let usr2Src = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
                usr2Src.setEventHandler { [weak controller] in
                    guard let controller else { return }
                    controller.applyMoodToAll(controller.currentMood)
                }
                usr2Src.resume()
                self.sigUSR2Source = usr2Src
            }

            let statusItem = StatusItemController(pickerEnabled: pickerEnabled, source: pickerSource, wallpaperController: controller)
            statusItem.onChooseVideo = { [weak controller] in
                controller?.reloadVideo()
            }
            statusItem.onRequestLocation = { [weak mood] in
                mood?.requestLocationOptIn()
            }
            statusItemController = statusItem
            mood.start()
        }
    }
}
