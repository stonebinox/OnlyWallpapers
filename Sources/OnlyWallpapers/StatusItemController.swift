import AppKit
import UniformTypeIdentifiers

final class StatusItemController {
    private let item: NSStatusItem
    private var copyInFlight: Bool = false
    private var chooseVideoItem: NSMenuItem?
    var onChooseVideo: (@MainActor () -> Void)?
    var onRequestLocation: (@MainActor () -> Void)?
    private weak var wallpaperController: WallpaperController?

    // pickerEnabled requires source=appstore AND assets dir writable; source alone is not enough.
    init(pickerEnabled: Bool, source: String, wallpaperController: WallpaperController?) {
        self.wallpaperController = wallpaperController
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "OnlyWallpapers")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.addItem(StatusItemController.makeAboutItem(target: self))
        let titleItem = NSMenuItem(title: "OnlyWallpapers", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        let chooseItem = NSMenuItem(title: "Choose video...", action: #selector(chooseVideoAction), keyEquivalent: "")
        chooseItem.target = self
        if !pickerEnabled {
            chooseItem.isEnabled = false
        }
        menu.addItem(chooseItem)
        chooseVideoItem = chooseItem
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_PICKER menuEnabled=\(chooseItem.isEnabled) source=\(source)\n".utf8))

        let framingMenu = NSMenu()
        let framingSubmenuItem = NSMenuItem(title: "Framing", action: nil, keyEquivalent: "")
        framingSubmenuItem.submenu = framingMenu

        let moveUpItem = NSMenuItem(title: "Move Up", action: #selector(framingMoveUp), keyEquivalent: "")
        moveUpItem.target = self
        framingMenu.addItem(moveUpItem)

        let moveDownItem = NSMenuItem(title: "Move Down", action: #selector(framingMoveDown), keyEquivalent: "")
        moveDownItem.target = self
        framingMenu.addItem(moveDownItem)

        let moveLeftItem = NSMenuItem(title: "Move Left", action: #selector(framingMoveLeft), keyEquivalent: "")
        moveLeftItem.target = self
        framingMenu.addItem(moveLeftItem)

        let moveRightItem = NSMenuItem(title: "Move Right", action: #selector(framingMoveRight), keyEquivalent: "")
        moveRightItem.target = self
        framingMenu.addItem(moveRightItem)

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(framingZoomIn), keyEquivalent: "")
        zoomInItem.target = self
        framingMenu.addItem(zoomInItem)

        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(framingZoomOut), keyEquivalent: "")
        zoomOutItem.target = self
        framingMenu.addItem(zoomOutItem)

        framingMenu.addItem(NSMenuItem.separator())

        let resetItem = NSMenuItem(title: "Reset Framing", action: #selector(framingReset), keyEquivalent: "")
        resetItem.target = self
        framingMenu.addItem(resetItem)

        menu.addItem(framingSubmenuItem)

        let locationItem = NSMenuItem(title: "Use location for weather tint", action: #selector(locationTintAction), keyEquivalent: "")
        locationItem.target = self
        menu.addItem(locationItem)

        let quitItem = NSMenuItem(title: "Quit OnlyWallpapers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = nil
        menu.addItem(quitItem)
        item.menu = menu
        let hasAbout = menu.items.contains { $0.title == AboutPanel.menuTitle }
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_STATUSITEM created=\(item.button != nil) about=\(hasAbout)\n".utf8))
    }

    static func makeAboutItem(target: AnyObject?) -> NSMenuItem {
        let aboutItem = NSMenuItem(title: AboutPanel.menuTitle, action: #selector(aboutAction), keyEquivalent: "")
        aboutItem.target = target
        return aboutItem
    }

    @objc func aboutAction() { AboutPanel.show() }

    // Test hook (OW_ABOUT_TEST): fires the real menu item exactly as a click would.
    @discardableResult
    func performAboutMenuItem() -> Bool {
        guard let menuItem = item.menu?.items.first(where: { $0.title == AboutPanel.menuTitle }),
              let action = menuItem.action else { return false }
        return NSApp.sendAction(action, to: menuItem.target, from: menuItem)
    }

    @objc private func framingMoveUp() { wallpaperController?.panYBy(-0.05) }
    @objc private func framingMoveDown() { wallpaperController?.panYBy(0.05) }
    @objc private func framingMoveLeft() { wallpaperController?.panXBy(-0.05) }
    @objc private func framingMoveRight() { wallpaperController?.panXBy(0.05) }
    @objc private func framingZoomIn() { wallpaperController?.zoomBy(0.1) }
    @objc private func framingZoomOut() { wallpaperController?.zoomBy(-0.1) }
    @objc private func framingReset() { wallpaperController?.resetFraming() }

    @objc private func locationTintAction() {
        NSApp.activate()
        onRequestLocation?()
    }

    @objc private func chooseVideoAction() {
        guard !copyInFlight, chooseVideoItem?.isEnabled == true else { return }
        copyInFlight = true
        chooseVideoItem?.isEnabled = false

        NSApp.activate()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType.mpeg4Movie]
            panel.level = .modalPanel
            if let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first,
               FileManager.default.fileExists(atPath: moviesURL.path) {
                panel.directoryURL = moviesURL
            }

            let response = panel.runModal()
            guard response == .OK, let srcURL = panel.url else {
                self.copyInFlight = false
                self.chooseVideoItem?.isEnabled = true
                return
            }

            let destDir = AppStorageManager.appSupportRoot().appendingPathComponent("web").appendingPathComponent("assets")
            Task.detached(priority: .userInitiated) {
                let result = copyVideoFile(from: srcURL, toAssetsDir: destDir)
                await MainActor.run {
                    switch result {
                    case .success:
                        self.onChooseVideo?()
                    case .failure(let err):
                        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_VIDEO slot=fail error=\(err.localizedDescription)\n".utf8))
                    }
                    self.copyInFlight = false
                    self.chooseVideoItem?.isEnabled = true
                }
            }
        }
    }
}

// Puts `srcURL` into the single bg.mp4 slot (.partial, then atomic swap). A source with an audio (or any non-video) track
// is written video-only with the video bitstream untouched (ow-blz.9); a video-only source takes the plain copy path.
// If the strip fails the original is copied instead, so the slot is never broken.
nonisolated func copyVideoFile(from srcURL: URL, toAssetsDir destDir: URL, stripper: VideoStripper = stripToVideoOnly) -> Result<Void, Error> {
    videoSlotLock.lock()
    defer { videoSlotLock.unlock() }
    let fm = FileManager.default
    let slotURL = destDir.appendingPathComponent("bg.mp4")
    cleanStalePartials(in: destDir)
    var partialURL = uniquePartialURL(in: destDir)

    do {
        let attrs = try fm.attributesOfItem(atPath: srcURL.path)
        let fileSize = (attrs[.size] as? Int) ?? 0
        let margin = max(fileSize, 10 * 1024 * 1024)

        if let fsAttrs = try? fm.attributesOfFileSystem(forPath: destDir.path),
           let freeBytes = fsAttrs[.systemFreeSize] as? Int,
           freeBytes < fileSize + margin {
            return .failure(NSError(domain: "OnlyWallpapers", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not enough free disk space."]))
        }

        if fm.fileExists(atPath: partialURL.path) {
            try fm.removeItem(at: partialURL)
        }

        var installedSize = fileSize
        var stripped = false
        if let summary = summarizeTracks(url: srcURL), summary.videoTracks >= 1, summary.otherTracks > 0 {
            do {
                let stats = try stripper(srcURL, partialURL)
                if let bad = validateStripped(src: srcURL, out: partialURL) { throw VideoStripError(reason: bad) }
                installedSize = stats.bytesOut
                stripped = true
                videoLog("strip=done \(stats.logFields)")
            } catch {
                discardPartial(partialURL, after: error)
                // The fallback copy never reuses the stripper's path: an export that did not stop could still write it.
                partialURL = uniquePartialURL(in: destDir)
                videoLog("strip=failed reason=\(error.localizedDescription)")
            }
        }
        if !stripped {
            try fm.copyItem(at: srcURL, to: partialURL)
            let copiedAttrs = try fm.attributesOfItem(atPath: partialURL.path)
            let copiedSize = (copiedAttrs[.size] as? Int) ?? 0
            if copiedSize != fileSize {
                try? fm.removeItem(at: partialURL)
                return .failure(NSError(domain: "OnlyWallpapers", code: 2, userInfo: [NSLocalizedDescriptionKey: "Copy size mismatch."]))
            }
        }

        // replaceItemAt requires the destination to exist; on first pick it does not.
        try installIntoSlot(partialURL: partialURL, slotURL: slotURL)

        videoLog("slot=ok bytes=\(installedSize)")
        return .success(())
    } catch {
        try? fm.removeItem(at: partialURL)
        return .failure(error)
    }
}
