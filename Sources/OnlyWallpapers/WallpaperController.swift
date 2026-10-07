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
    let descriptor: ScreenDescriptor
    let window: WallpaperWindow?
    let webView: WebWallpaperView?
    let geometry: WallpaperSliceGeometry
}

// MARK: - computeLayout (pure, testable)

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

// MARK: - WallpaperController

final class WallpaperController {

    private(set) var currentMood: MoodParams = .neutral
    private var records: [WallpaperScreenRecord] = []
    private var committedDescriptors: [ScreenDescriptor] = []
    private var reducer = WallpaperRefreshReducer()
    private var commitGen: Int = 0
    private var scheduleGen: Int = 0
    nonisolated(unsafe) private var pendingItem: DispatchWorkItem?
    nonisolated(unsafe) private var screenObserver: Any?
    nonisolated(unsafe) private var wakeObserver: Any?
    private let isFakeMode: Bool
    private let fakeScreensFile: String?

    init() {
        let env = ProcessInfo.processInfo.environment
        self.fakeScreensFile = env["OW_FAKE_SCREENS_FILE"]
        self.isFakeMode = self.fakeScreensFile != nil
    }

    deinit {
        pendingItem?.cancel()
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
    }

    func initialBuild() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleRefresh(reason: "screens-changed") }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleRefresh(reason: "wake") }
        }

        let descriptors = currentScreenDescriptors()
        performCommit(descriptors, reason: "initial")
    }

    // FIX 3: force a recommit using real NSScreen.screens, bypassing the reducer no-op.
    // Only installed when OW_REBUILD_TEST=1 (and not fake mode) in AppDelegate.
    // Applies a fixed delta K=137 to each slice so the applied oracle proves the stage
    // actually MOVED to the commanded value, not left at the previously-correct value.
    // Real add/remove of a display is a Phase 5 check (no third display in CI).
    func forceRecommit() {
        let descriptors = currentScreenDescriptors()
        performCommit(descriptors, reason: "forced", sliceDelta: 137)
    }

    private func currentScreenDescriptors() -> [ScreenDescriptor] {
        if let path = fakeScreensFile {
            return parseFakeScreens(path: path)
        }
        // FIX 1: when NSScreenNumber is absent or zero, synthesize a unique sentinel
        // per screen index. Sentinels use the high bit (0x80000000+idx) so they cannot
        // collide with real CGDirectDisplayIDs, which are small positive integers.
        return NSScreen.screens.enumerated().map { (idx, screen) in
            let rawID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let did: CGDirectDisplayID
            if let id = rawID, id != 0 {
                did = id
            } else {
                did = 0x8000_0000 | CGDirectDisplayID(idx)
                FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WARN displayID=missing screenIdx=\(idx) name=\(screen.localizedName) fallback=\(did)\n".utf8))
            }
            let scale = screen.backingScaleFactor
            let f = screen.frame
            return ScreenDescriptor(
                displayID: did,
                frame: f,
                scale: scale,
                pixelW: Int(f.width * scale),
                pixelH: Int(f.height * scale))
        }
    }

    private func parseFakeScreens(path: String) -> [ScreenDescriptor] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var result: [ScreenDescriptor] = []
        let lines = content.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.components(separatedBy: ",")
            guard parts.count >= 4,
                  let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let y = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  let w = Double(parts[2].trimmingCharacters(in: .whitespaces)),
                  let h = Double(parts[3].trimmingCharacters(in: .whitespaces)) else { continue }
            let scale: CGFloat = parts.count >= 5 ? (Double(parts[4].trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } ?? 2.0) : 2.0
            let did: CGDirectDisplayID
            if parts.count >= 6, let d = UInt32(parts[5].trimmingCharacters(in: .whitespaces)) {
                did = d == 0 ? CGDirectDisplayID(idx + 1) : d
            } else {
                did = CGDirectDisplayID(idx + 1)
            }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            result.append(ScreenDescriptor(
                displayID: did,
                frame: frame,
                scale: scale,
                pixelW: Int(w * Double(scale)),
                pixelH: Int(h * Double(scale))))
        }
        return result
    }

    private func scheduleRefresh(reason: String) {
        pendingItem?.cancel()
        pendingItem = nil
        scheduleGen += 1
        let capturedGen = scheduleGen
        let snapshot = currentScreenDescriptors()

        let action = reducer.snapshot(snapshot, committed: committedDescriptors)

        switch action {
        case .none:
            let g = commitGen
            let n = records.count
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_REBUILD gen=\(g) reason=noop old=\(n) new=\(n)\n".utf8))

        case .scheduleDebounce:
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.scheduleGen == capturedGen else { return }
                let result = self.reducer.debounceFired(capturedGen: capturedGen, currentGen: self.scheduleGen)
                self.applyAction(result, reason: reason)
            }
            pendingItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)

        case .scheduleEmptyConfirm:
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.scheduleGen == capturedGen else { return }
                let result = self.reducer.emptyConfirmFired(capturedGen: capturedGen, currentGen: self.scheduleGen)
                self.applyAction(result, reason: reason)
            }
            pendingItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)

        case .commit(let next):
            performCommit(next, reason: reason)

        case .commitEmpty:
            performCommit([], reason: reason)

        case .dropStale:
            break
        }
    }

    private func applyAction(_ action: RefreshAction, reason: String) {
        switch action {
        case .commit(let next):
            performCommit(next, reason: reason)
        case .commitEmpty:
            performCommit([], reason: reason)
        case .dropStale, .none:
            break
        default:
            break
        }
    }

    private func performCommit(_ descriptors: [ScreenDescriptor], reason: String, sliceDelta: CGFloat = 0) {
        let gen = commitGen
        commitGen += 1

        let envWebDir = ProcessInfo.processInfo.environment["WALLPAPER_WEB_DIR"]
            .flatMap { p in p.isEmpty ? nil : URL(fileURLWithPath: p) }
        let webDir: URL? = isFakeMode ? envWebDir : Optional(WebDirectoryResolver.resolve().url)
        let oldCount = records.count
        let newCount = descriptors.count

        let (_, baseSlices) = computeLayout(descriptors.map { $0.frame })
        let slices: [WallpaperSliceGeometry] = sliceDelta != 0
            ? baseSlices.map { WallpaperSliceGeometry(stageW: $0.stageW, stageH: $0.stageH, offX: $0.offX + sliceDelta, offY: $0.offY + sliceDelta) }
            : baseSlices

        let nextIDs = Set(descriptors.map { $0.displayID })

        // RETIRE removed screens
        for rec in records where !nextIDs.contains(rec.displayID) {
            let winNum = rec.window?.windowNumber ?? 0
            if !isFakeMode {
                rec.webView?.stopLoading()
                rec.webView?.navigationDelegate = nil
                rec.window?.contentView = nil
                rec.window?.close()
            }
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_RETIRE win=\(winNum) did=\(rec.displayID) gen=\(gen)\n".utf8))
        }

        var newRecords: [WallpaperScreenRecord] = []

        // Keyed by displayID so duplicate IDs overwrite (no linear first-match aliasing).
        let existingByID: [CGDirectDisplayID: WallpaperScreenRecord] = Dictionary(
            records.map { ($0.displayID, $0) },
            uniquingKeysWith: { _, last in last }
        )

        for (i, desc) in descriptors.enumerated() {
            let geo = slices[i]

            if let existing = existingByID[desc.displayID] {
                // UPDATE survivor: geometry always applied so overlay backing resizes; window frame skipped in fake mode.
                if !isFakeMode { existing.window?.updateFrame(desc.frame) }
                existing.webView?.applyGeometry(geo, gen: gen)
                newRecords.append(WallpaperScreenRecord(
                    displayID: desc.displayID,
                    descriptor: desc,
                    window: existing.window,
                    webView: existing.webView,
                    geometry: geo))
            } else {
                // ADD newcomer
                if let webDir = webDir {
                    // FIX 5: pass commitGen so loaded=ok and applied lines carry the commit gen
                    let webView = WebWallpaperView(
                        frame: NSRect(origin: .zero, size: desc.frame.size),
                        webDirectory: webDir,
                        screenName: "Display-\(desc.displayID)",
                        geometry: geo,
                        commitGen: gen,
                        initialFraming: AppStorageManager.currentFraming,
                        initialMood: currentMood)
                    let win = WallpaperWindow(frame: desc.frame, contentView: webView)
                    win.orderFrontRegardless()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak win] in
                        win?.logPlacement(screenName: "Display-\(desc.displayID)")
                    }
                    newRecords.append(WallpaperScreenRecord(
                        displayID: desc.displayID,
                        descriptor: desc,
                        window: win,
                        webView: webView,
                        geometry: geo))
                } else {
                    newRecords.append(WallpaperScreenRecord(
                        displayID: desc.displayID,
                        descriptor: desc,
                        window: nil,
                        webView: nil,
                        geometry: geo))
                }
            }
        }

        records = newRecords
        committedDescriptors = descriptors
        reducer.pendingState = .idle

        // TELEMETRY (FIX 4: new=0 and count=0 are already present when descriptors is empty)
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_REBUILD gen=\(gen) reason=\(reason) old=\(oldCount) new=\(newCount)\n".utf8))
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WINDOWS count=\(newCount) gen=\(gen)\n".utf8))

        for rec in newRecords {
            let winNum = rec.window?.windowNumber ?? 0
            let f = rec.descriptor.frame
            let g = rec.geometry
            let line = String(
                format: "ONLYWALLPAPERS_SLICE did=%u win=%ld frame=%.4f,%.4f,%.4f,%.4f stageW=%.4f stageH=%.4f offX=%.4f offY=%.4f screen=Display-%u gen=%d\n",
                rec.displayID, winNum,
                f.minX, f.minY, f.width, f.height,
                g.stageW, g.stageH, g.offX, g.offY,
                rec.displayID, gen)
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    private var reloadToken: Int = 0

    private func pollVideoApplied(view: WebWallpaperView, token: Int, winNum: Int, attempt: Int) {
        view.evaluateJavaScript("window.__lastVideoApplied || {src:'',durationMs:0}") { [weak self, weak view] result, _ in
            guard let view else { return }
            let obj = result as? [String: Any]
            let durMs = (obj?["durationMs"] as? NSNumber)?.intValue ?? 0
            let src = (obj?["src"] as? String) ?? ""
            if durMs > 0 || attempt >= 30 {
                FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_VIDEO applied win=\(winNum) rev=\(token) durationMs=\(durMs) currentSrc=\(src)\n".utf8))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak view] in
                    guard let view else { return }
                    view.requestMediaPlaybackState { state in
                        let ms: String
                        switch state {
                        case .none: ms = "none"
                        case .paused: ms = "paused"
                        case .suspended: ms = "suspended"
                        case .playing: ms = "playing"
                        @unknown default: ms = "unknown"
                        }
                        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_VIDEO media win=\(winNum) rev=\(token) state=\(ms)\n".utf8))
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.pollVideoApplied(view: view, token: token, winNum: winNum, attempt: attempt + 1)
                }
            }
        }
    }

    func reloadVideo() {
        reloadToken += 1
        let token = reloadToken
        var viewCount = 0
        for rec in records {
            guard let view = rec.webView else { continue }
            viewCount += 1
            let winNum = rec.window?.windowNumber ?? 0
            let js = "window.__setWallpaperVideo('assets/bg.mp4?rev=\(token)')"
            view.evaluateJavaScript(js) { [weak self, weak view, token, winNum] _, _ in
                guard let self, let view else { return }
                self.pollVideoApplied(view: view, token: token, winNum: winNum, attempt: 0)
            }
        }
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_VIDEO reload views=\(viewCount) rev=\(token)\n".utf8))
    }

    func applyFramingToAll() {
        let cfg = AppStorageManager.currentFraming
        for rec in records {
            rec.webView?.applyFraming(cfg)
        }
    }

    func applyMoodToAll(_ params: MoodParams) {
        currentMood = params
        for rec in records {
            rec.webView?.applyMood(params)
        }
    }

    private func updateFraming(_ cfg: AppStorageManager.FramingConfig) {
        AppStorageManager.currentFraming = cfg
        if !AppStorageManager.writeFraming(cfg) {
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_FRAMING persist=fail\n".utf8))
        }
        applyFramingToAll()
    }

    func zoomBy(_ delta: Double) {
        let c = AppStorageManager.currentFraming
        let newZoom = min(max(c.zoom + delta, 1), 2)
        updateFraming(AppStorageManager.FramingConfig(zoom: newZoom, panX: c.panX, panY: c.panY))
    }

    func panXBy(_ delta: Double) {
        let c = AppStorageManager.currentFraming
        let newX = min(max(c.panX + delta, -1), 1)
        updateFraming(AppStorageManager.FramingConfig(zoom: c.zoom, panX: newX, panY: c.panY))
    }

    func panYBy(_ delta: Double) {
        let c = AppStorageManager.currentFraming
        let newY = min(max(c.panY + delta, -1), 1)
        updateFraming(AppStorageManager.FramingConfig(zoom: c.zoom, panX: c.panX, panY: newY))
    }

    func resetFraming() {
        updateFraming(AppStorageManager.FramingConfig(zoom: 1, panX: 0, panY: 0))
    }

    func reloadFramingFromDisk() {
        AppStorageManager.currentFraming = AppStorageManager.readFraming()
        applyFramingToAll()
    }
}
