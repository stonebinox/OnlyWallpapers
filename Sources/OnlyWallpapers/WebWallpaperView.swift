import AppKit
import WebKit

final class WebWallpaperView: WKWebView, WKNavigationDelegate {

    let screenName: String
    let webDirectory: URL
    let index: URL
    // FIX 5: gen of the commit that created this view, carried on loaded=ok and applied lines.
    private let commitGen: Int
    private let injectionStatus: String
    // Init-snapshot values for the ONLYWALLPAPERS_WEB_GEOMETRY log (document-start injection).
    private let rsW: CGFloat
    private let rsH: CGFloat
    private let rOffX: CGFloat
    private let rOffY: CGFloat
    // FIX 2: pending-geometry state. latestGeometry is nil until applyGeometry is called.
    private var latestGeometry: WallpaperSliceGeometry?
    private var latestGen: Int = 0
    private var isLoaded: Bool = false

    init(frame: NSRect, webDirectory: URL, screenName: String, geometry: WallpaperSliceGeometry, commitGen: Int) {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        self.screenName = screenName
        self.webDirectory = webDirectory
        self.commitGen = commitGen
        let dir = webDirectory.standardizedFileURL
        let index = dir.appendingPathComponent("index.html")
        self.index = index

        let rsW = geometry.stageW.rounded()
        let rsH = geometry.stageH.rounded()
        let rOffX = geometry.offX.rounded()
        let rOffY = geometry.offY.rounded()
        self.rsW = rsW
        self.rsH = rsH
        self.rOffX = rOffX
        self.rOffY = rOffY

        var injectionStatus = "skipped reason=non-finite"
        if rsW.isFinite && rsH.isFinite && rOffX.isFinite && rOffY.isFinite {
            injectionStatus = "skipped reason=json"
            let payload: [String: Double] = [
                "stageW": Double(rsW),
                "stageH": Double(rsH),
                "offX": Double(rOffX),
                "offY": Double(rOffY)
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                let script = WKUserScript(
                    source: "window.__wallpaper = \(json);",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
                config.userContentController.addUserScript(script)
                injectionStatus = "atDocumentStart"
            }
        }
        self.injectionStatus = injectionStatus

        super.init(frame: frame, configuration: config)
        // On macOS 26, the public transparency path (underPageBackgroundColor + transparent CSS)
        // leaves the WKWebView base opaque. The page supplies the backdrop (black fallback here;
        // full-bleed video in ow-94b.2). True desktop-through transparency would require the
        // semi-private drawsBackground KVC, which is deferred (tracked for Epic D).
        // underPageBackgroundColor is kept: it is harmless and future-relevant.
        self.underPageBackgroundColor = .clear
        self.navigationDelegate = self
        let exists = FileManager.default.fileExists(atPath: index.path)
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WEB dir=\(dir.path) index_exists=\(exists)\n".utf8))
        self.loadFileURL(index, allowingReadAccessTo: dir)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // FIX 2: store the latest requested geometry. If the page is loaded, apply immediately.
    // If not loaded yet, the stored geometry wins in didFinish (last-write-wins).
    func applyGeometry(_ g: WallpaperSliceGeometry, gen: Int) {
        let rW = g.stageW.rounded()
        let rH = g.stageH.rounded()
        let rX = g.offX.rounded()
        let rY = g.offY.rounded()
        guard rW.isFinite && rH.isFinite && rX.isFinite && rY.isFinite else { return }
        latestGeometry = g
        latestGen = gen
        guard isLoaded else { return }
        applyAndLog(rW: rW, rH: rH, rX: rX, rY: rY, gen: gen)
    }

    // FIX 2 + FIX 5: gen-guarded apply. Stale completions are dropped (last-write-wins).
    private func applyAndLog(rW: CGFloat, rH: CGFloat, rX: CGFloat, rY: CGFloat, gen: Int) {
        let js = String(
            format: "window.__applyWallpaperGeometry({stageW:%.0f,stageH:%.0f,offX:%.0f,offY:%.0f})",
            Double(rW), Double(rH), Double(rX), Double(rY))
        let capturedGen = gen
        self.evaluateJavaScript(js) { [weak self] _, _ in
            guard let self, self.latestGen == capturedGen else { return }
            self.evaluateJavaScript("JSON.stringify(window.__wallpaperApplied || null)") { [weak self] result, _ in
                guard let self, self.latestGen == capturedGen else { return }
                let win = self.window?.windowNumber ?? 0
                guard let str = result as? String,
                      let data = str.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let l = (obj["left"] as? NSNumber)?.doubleValue,
                      let t = (obj["top"] as? NSNumber)?.doubleValue,
                      let w = (obj["width"] as? NSNumber)?.doubleValue,
                      let h = (obj["height"] as? NSNumber)?.doubleValue else { return }
                let line = String(format: "ONLYWALLPAPERS_WEB applied win=%ld left=%.4f top=%.4f width=%.4f height=%.4f gen=%d\n",
                                  win, l, t, w, h, capturedGen)
                FileHandle.standardOutput.write(Data(line.utf8))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        let win = self.window?.windowNumber ?? 0
        // Use the latest requested gen if applyGeometry has already advanced past commitGen.
        let loadedGen = latestGeometry != nil ? latestGen : commitGen
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WEB screen=\(screenName) win=\(win) loaded=ok frame=\(Int(self.bounds.width))x\(Int(self.bounds.height)) gen=\(loadedGen)\n".utf8))
        let geoLine = String(
            format: "ONLYWALLPAPERS_WEB_GEOMETRY screen=%@ win=%ld gW=%.4f gH=%.4f gX=%.4f gY=%.4f injection=%@\n",
            screenName, win,
            Double(rsW), Double(rsH), Double(rOffX), Double(rOffY),
            injectionStatus)
        FileHandle.standardOutput.write(Data(geoLine.utf8))

        // FIX 2: re-apply the latest pending geometry so a rapid arrangement change before
        // load completes still gets the newest geometry applied, not the init injection.
        if let g = latestGeometry {
            let rW = g.stageW.rounded()
            let rH = g.stageH.rounded()
            let rX = g.offX.rounded()
            let rY = g.offY.rounded()
            if rW.isFinite && rH.isFinite && rX.isFinite && rY.isFinite {
                applyAndLog(rW: rW, rH: rH, rX: rX, rY: rY, gen: latestGen)
            }
        } else {
            // No applyGeometry calls made yet; read back what the document-start injection set.
            self.evaluateJavaScript("JSON.stringify(window.__wallpaperApplied || null)") { [weak self] result, _ in
                // Drop if applyGeometry advanced the gen while JS was evaluating (last-write-wins).
                guard let self, self.latestGeometry == nil else { return }
                let win = self.window?.windowNumber ?? 0
                if let str = result as? String,
                   let data = str.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let l = (obj["left"] as? NSNumber)?.doubleValue,
                   let t = (obj["top"] as? NSNumber)?.doubleValue,
                   let w = (obj["width"] as? NSNumber)?.doubleValue,
                   let h = (obj["height"] as? NSNumber)?.doubleValue {
                    let line = String(format: "ONLYWALLPAPERS_WEB applied win=%ld left=%.4f top=%.4f width=%.4f height=%.4f gen=%d\n",
                                      win, l, t, w, h, self.commitGen)
                    FileHandle.standardOutput.write(Data(line.utf8))
                } else {
                    FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WEB applied win=\(win) applied=fail gen=\(self.commitGen)\n".utf8))
                }
            }
        }

        for delay in [1.0, 2.5, 7.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let sn = self.screenName
                let wn = self.window?.windowNumber ?? 0
                self.requestMediaPlaybackState { state in
                    let ms: String
                    switch state {
                    case .none: ms = "none"
                    case .paused: ms = "paused"
                    case .suspended: ms = "suspended"
                    case .playing: ms = "playing"
                    @unknown default: ms = "unknown"
                    }
                    FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WEB screen=\(sn) win=\(wn) media=\(ms) t=\(delay)\n".utf8))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WEB screen=\(screenName) loaded=fail error=\(error.localizedDescription) url=\(index.path)\n".utf8))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WEB screen=\(screenName) loaded=fail error=\(error.localizedDescription) url=\(index.path)\n".utf8))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WEB screen=\(screenName) terminated\n".utf8))
    }
}
