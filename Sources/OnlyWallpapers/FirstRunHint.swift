import AppKit

enum FirstRunHint {
    static let title = "OnlyWallpapers is running"
    static let message = "OnlyWallpapers lives in the Dock and the menu bar (the icon at the top right of your screen). The wallpaper starts black. Choose \"Choose video...\" from the menu bar icon to pick a video (an .mp4)."

    // Pure decision. Any OW_* variable (every gate and test hook uses one), a dev
    // WALLPAPER_WEB_DIR, or an explicit OW_SUPPRESS_FIRST_RUN=1 suppresses the modal.
    // OW_FIRSTRUN_TEST=1 overrides the generic suppression only (alreadyShown and
    // OW_SUPPRESS_FIRST_RUN still win).
    static func shouldShow(env: [String: String], alreadyShown: Bool) -> Bool {
        if alreadyShown { return false }
        if env["OW_SUPPRESS_FIRST_RUN"] == "1" { return false }
        if env["OW_FIRSTRUN_TEST"] == "1" { return true }
        if env.keys.contains(where: { $0.hasPrefix("OW_") }) { return false }
        if let dir = env["WALLPAPER_WEB_DIR"], !dir.isEmpty { return false }
        return true
    }

    // Marks the flag before presenting so a crash or force quit never re-shows it.
    // If the flag cannot be persisted the hint is skipped, otherwise it would repeat every launch.
    static func claim(persist: () -> Bool) -> Bool {
        if persist() { return true }
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_FIRSTRUN shown=false reason=persist_failed\n".utf8))
        return false
    }

    static func showIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard shouldShow(env: env, alreadyShown: AppStorageManager.readFirstRunHintShown()) else { return }
        guard claim(persist: { AppStorageManager.writeFirstRunHintShown() }) else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_FIRSTRUN shown=true\n".utf8))
        if env["OW_FIRSTRUN_TEST"] == "1" {
            let timer = Timer(timeInterval: 1.0, repeats: false) { _ in MainActor.assumeIsolated { NSApp.abortModal() } }
            RunLoop.main.add(timer, forMode: .common)
        }
        alert.runModal()
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_FIRSTRUN dismissed=true\n".utf8))
    }
}
