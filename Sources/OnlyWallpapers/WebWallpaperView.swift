import AppKit
import WebKit

final class WebWallpaperView: WKWebView, WKNavigationDelegate {

    let screenName: String
    let webDirectory: URL
    let index: URL
    private let geometry: WallpaperSliceGeometry
    private let injectionStatus: String
    private let rsW: CGFloat
    private let rsH: CGFloat
    private let rOffX: CGFloat
    private let rOffY: CGFloat

    init(frame: NSRect, webDirectory: URL, screenName: String, geometry: WallpaperSliceGeometry) {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        self.screenName = screenName
        self.webDirectory = webDirectory
        let dir = webDirectory.standardizedFileURL
        let index = dir.appendingPathComponent("index.html")
        self.index = index
        self.geometry = geometry

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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let win = self.window?.windowNumber ?? 0
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WEB screen=\(screenName) win=\(win) loaded=ok frame=\(Int(self.bounds.width))x\(Int(self.bounds.height))\n".utf8))
        let geoLine = String(
            format: "ONLYWALLPAPERS_WEB_GEOMETRY screen=%@ win=%ld gW=%.4f gH=%.4f gX=%.4f gY=%.4f injection=%@\n",
            screenName, win,
            Double(rsW), Double(rsH), Double(rOffX), Double(rOffY),
            injectionStatus)
        FileHandle.standardOutput.write(Data(geoLine.utf8))
        self.evaluateJavaScript("JSON.stringify(window.__wallpaperApplied || null)") { result, _ in
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let l = (obj["left"] as? NSNumber)?.doubleValue,
               let t = (obj["top"] as? NSNumber)?.doubleValue,
               let w = (obj["width"] as? NSNumber)?.doubleValue,
               let h = (obj["height"] as? NSNumber)?.doubleValue {
                let line = String(format: "ONLYWALLPAPERS_WEB applied win=%ld left=%.4f top=%.4f width=%.4f height=%.4f\n", win, l, t, w, h)
                FileHandle.standardOutput.write(Data(line.utf8))
            } else {
                FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WEB applied win=\(win) applied=fail\n".utf8))
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
