import AppKit
import WebKit

final class WebWallpaperView: WKWebView, WKNavigationDelegate {

    let screenName: String
    let webDirectory: URL
    let index: URL

    init(frame: NSRect, webDirectory: URL, screenName: String) {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        self.screenName = screenName
        self.webDirectory = webDirectory
        let dir = webDirectory.standardizedFileURL
        let index = dir.appendingPathComponent("index.html")
        self.index = index
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
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_WEB screen=\(screenName) win=\(self.window?.windowNumber ?? 0) loaded=ok frame=\(Int(self.bounds.width))x\(Int(self.bounds.height))\n".utf8))
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
