import AppKit
import CoreGraphics

// MARK: - WallpaperWindow

final class WallpaperWindow: NSWindow {

    init(screen: NSScreen, contentView: NSView) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.ignoresMouseEvents = true
        self.hidesOnDeactivate = false
        self.hasShadow = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isReleasedWhenClosed = false
        self.contentView = contentView
        self.setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // logPlacement emits one diagnostic line after the window is on screen,
    // confirming the actual CG layer and z-order relative to the desktop-icon level.
    func logPlacement(screenName: String) {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            let line = "ONLYWALLPAPERS_WINDOW screen=\(screenName) level=\(self.level.rawValue) win=\(self.windowNumber) layer=unknown zorder_ok=unknown\n"
            FileHandle.standardOutput.write(Data(line.utf8))
            return
        }

        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let selfWindowNumber = self.windowNumber
        var selfLayer: Int?

        for info in windowList {
            let number = info[kCGWindowNumber as String] as? Int ?? -1
            let layer = info[kCGWindowLayer as String] as? Int ?? Int.max
            if number == selfWindowNumber {
                selfLayer = layer
                break
            }
        }

        let layerStr = selfLayer.map { "\($0)" } ?? "unknown"
        let zorderOK: String
        if let sl = selfLayer {
            zorderOK = sl < iconLevel ? "true" : "false"
        } else {
            zorderOK = "unknown"
        }

        let mouse = self.ignoresMouseEvents
        let cbAllSpaces = self.collectionBehavior.contains(.canJoinAllSpaces)
        let cbStationary = self.collectionBehavior.contains(.stationary)
        let cbIgnoresCycle = self.collectionBehavior.contains(.ignoresCycle)
        let line = "ONLYWALLPAPERS_WINDOW screen=\(screenName) level=\(self.level.rawValue) win=\(self.windowNumber) layer=\(layerStr) zorder_ok=\(zorderOK) mouse=\(mouse) cb_allspaces=\(cbAllSpaces) cb_stationary=\(cbStationary) cb_ignorescycle=\(cbIgnoresCycle)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
