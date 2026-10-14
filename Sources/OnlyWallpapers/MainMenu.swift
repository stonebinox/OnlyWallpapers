import AppKit

// Standard app menu for the regular (Dock) activation policy. The wallpaper windows are
// click-through and never key, so this menu bar is the app's only keyboard surface.
enum MainMenu {
    static let appName = "OnlyWallpapers"

    // Titles in order; "-" is a separator. Pure so the selftest can assert the shape.
    static let appMenuTitles: [String] = [
        "About \(appName)", "-", "Hide \(appName)", "Hide Others", "Show All", "-", "Quit \(appName)"
    ]

    @MainActor
    static func build(aboutTarget: AnyObject?, aboutAction: Selector) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)

        let appMenu = NSMenu(title: appName)

        let about = NSMenuItem(title: appMenuTitles[0], action: aboutAction, keyEquivalent: "")
        about.target = aboutTarget
        appMenu.addItem(about)
        appMenu.addItem(NSMenuItem.separator())

        let hide = NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hide)

        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)

        let showAll = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(showAll)

        appMenu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)

        appItem.submenu = appMenu
        return main
    }
}
