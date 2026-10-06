import AppKit
import UniformTypeIdentifiers

final class StatusItemController {
    private let item: NSStatusItem
    private var copyInFlight: Bool = false
    private var chooseVideoItem: NSMenuItem?
    var onChooseVideo: (@MainActor () -> Void)?
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

        let quitItem = NSMenuItem(title: "Quit OnlyWallpapers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = nil
        menu.addItem(quitItem)
        item.menu = menu
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_STATUSITEM created=\(item.button != nil)\n".utf8))
    }

    @objc private func framingMoveUp() { wallpaperController?.panYBy(-0.05) }
    @objc private func framingMoveDown() { wallpaperController?.panYBy(0.05) }
    @objc private func framingMoveLeft() { wallpaperController?.panXBy(-0.05) }
    @objc private func framingMoveRight() { wallpaperController?.panXBy(0.05) }
    @objc private func framingZoomIn() { wallpaperController?.zoomBy(0.1) }
    @objc private func framingZoomOut() { wallpaperController?.zoomBy(-0.1) }
    @objc private func framingReset() { wallpaperController?.resetFraming() }

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

nonisolated func copyVideoFile(from srcURL: URL, toAssetsDir destDir: URL) -> Result<Void, Error> {
    let fm = FileManager.default
    let slotURL = destDir.appendingPathComponent("bg.mp4")
    let partialURL = destDir.appendingPathComponent("bg.mp4.partial")

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
        try fm.copyItem(at: srcURL, to: partialURL)
        let copiedAttrs = try fm.attributesOfItem(atPath: partialURL.path)
        let copiedSize = (copiedAttrs[.size] as? Int) ?? 0
        if copiedSize != fileSize {
            try? fm.removeItem(at: partialURL)
            return .failure(NSError(domain: "OnlyWallpapers", code: 2, userInfo: [NSLocalizedDescriptionKey: "Copy size mismatch."]))
        }

        // FIX 4: replaceItemAt requires the destination to exist; on first pick it does not.
        // Use moveItem when the slot is absent; replaceItemAt when it exists (atomic swap).
        if fm.fileExists(atPath: slotURL.path) {
            _ = try fm.replaceItemAt(slotURL, withItemAt: partialURL)
        } else {
            try fm.moveItem(at: partialURL, to: slotURL)
        }

        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_VIDEO slot=ok bytes=\(copiedSize)\n".utf8))
        return .success(())
    } catch {
        try? fm.removeItem(at: partialURL)
        return .failure(error)
    }
}
