import AppKit
import CoreGraphics

// MARK: - WallpaperSliceGeometry

struct WallpaperSliceGeometry: Equatable {
    let stageW: CGFloat
    let stageH: CGFloat
    let offX: CGFloat
    let offY: CGFloat
}

// MARK: - WallpaperScreenRecord

struct WallpaperScreenRecord {
    let displayID: CGDirectDisplayID
    let window: WallpaperWindow
    let geometry: WallpaperSliceGeometry
}

// MARK: - WallpaperController

final class WallpaperController {

    private var records: [WallpaperScreenRecord] = []

    private let webDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("web", isDirectory: true)
        .standardizedFileURL

    nonisolated func computeLayout(_ frames: [CGRect]) -> (union: CGRect, slices: [WallpaperSliceGeometry]) {
        if frames.isEmpty { return (.zero, []) }
        let union = frames.reduce(CGRect.null) { $0.union($1) }
        let slices = frames.map { f in
            WallpaperSliceGeometry(
                stageW: union.width, stageH: union.height,
                offX: f.minX - union.minX,
                offY: union.maxY - f.maxY)
        }
        return (union, slices)
    }

    func build() {
        guard records.isEmpty else { return }
        let screens = NSScreen.screens
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WINDOWS count=\(screens.count)\n".utf8))
        let (_, slices) = computeLayout(screens.map { $0.frame })
        for (i, screen) in screens.enumerated() {
            let geo = slices[i]
            let did = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let webView = WebWallpaperView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                webDirectory: webDir,
                screenName: screen.localizedName
            )
            let win = WallpaperWindow(screen: screen, contentView: webView)
            win.orderFrontRegardless()
            records.append(WallpaperScreenRecord(displayID: did, window: win, geometry: geo))
            let name = screen.localizedName
            let f = screen.frame
            let line = String(
                format: "ONLYWALLPAPERS_SLICE did=%u win=%ld frame=%.4f,%.4f,%.4f,%.4f stageW=%.4f stageH=%.4f offX=%.4f offY=%.4f screen=%@\n",
                did, win.windowNumber, f.minX, f.minY, f.width, f.height,
                geo.stageW, geo.stageH, geo.offX, geo.offY, name)
            FileHandle.standardOutput.write(Data(line.utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak win] in
                win?.logPlacement(screenName: name)
            }
        }
    }
}
