import AppKit

final class StatusItemController {
    private let item: NSStatusItem

    init() {
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
        let quitItem = NSMenuItem(title: "Quit OnlyWallpapers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = nil
        menu.addItem(quitItem)
        item.menu = menu
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_STATUSITEM created=\(item.button != nil)\n".utf8))
    }
}
