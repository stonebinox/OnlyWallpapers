import AppKit

enum AboutPanel {
    static let menuTitle = "About OnlyWallpapers"
    static let authorName = "Anoop Santhanam"
    static let authorURL = "https://anoopsanthanam.com"
    static let weatherURL = "https://open-meteo.com"

    // Testable builder: centered credits with two clickable links.
    static func makeCredits() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]
        func link(_ text: String, _ url: String) -> NSAttributedString {
            var attrs = base
            attrs[.link] = URL(string: url)!
            return NSAttributedString(string: text, attributes: attrs)
        }
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "by \(authorName)\n", attributes: base))
        out.append(link("anoopsanthanam.com", authorURL))
        out.append(NSAttributedString(string: "\n\nWeather data by ", attributes: base))
        out.append(link("Open-Meteo.com", weatherURL))
        return out
    }

    static func versionString() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    static func buildString() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
    }

    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "OnlyWallpapers",
            .applicationVersion: versionString(),
            .version: buildString(),
            .credits: makeCredits()
        ])
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_ABOUT shown=true\n".utf8))
    }

    static func linkCount(in credits: NSAttributedString) -> Int {
        var n = 0
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { v, _, _ in
            if v != nil { n += 1 }
        }
        return n
    }

    // OW_ABOUT_TEST: trigger the menu item's own action, then confirm a new window is on screen.
    static func runTestHook(statusItem: StatusItemController?) {
        let before = Set(NSApp.windows.filter { $0.isVisible }.map { $0.windowNumber })
        let fired = statusItem?.performAboutMenuItem() ?? false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let panels = NSApp.windows.filter { $0.isVisible && !before.contains($0.windowNumber) }
            let visible = fired && !panels.isEmpty
            let links = linkCount(in: makeCredits())
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_ABOUT_CHECK visible=\(visible) version=\(versionString()) credits_links=\(links)\n".utf8))
            panels.forEach { $0.close() }
        }
    }
}
