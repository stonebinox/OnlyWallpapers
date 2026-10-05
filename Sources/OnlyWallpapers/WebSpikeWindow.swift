// SPIKE: This file is a diagnostic spike for WKWebView desktop-layer rendering.
// It is the ONLY file allowed to reference WKWebView or WKWebViewConfiguration.
// Remove or gate behind a compile flag before shipping.

import AppKit
import WebKit
import CoreGraphics

// MARK: - Message handler (separate class to avoid retain cycles)

final class WebSpikeMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        var parts: [String] = ["OW_WEBSPIKE JS"]
        parts.append("t=\(String(format: "%.3f", uptime))")
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            parts.append("\(k)=\(v)")
        }
        let line = parts.joined(separator: " ") + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}

// MARK: - Controller

final class WebSpikeController: NSObject, WKNavigationDelegate {

    // MARK: Properties

    let screenName: String
    let displayID: UInt32
    let webView: WKWebView
    let window: NSWindow
    let messageHandler: WebSpikeMessageHandler
    var heartbeatTimer: Timer?
    var mediaState: String = "unknown"

    // MARK: Init

    init(screen: NSScreen, webDir: URL, filtered: Bool, clearMode: Bool) {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        screenName = screen.localizedName

        messageHandler = WebSpikeMessageHandler()

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(messageHandler, name: "owspike")

        let wv = WKWebView(frame: screen.frame, configuration: config)
        wv.underPageBackgroundColor = .clear
        webView = wv

        window = WebSpikeController.makeWebSpikeWindow(for: screen, webView: wv)

        super.init()

        webView.navigationDelegate = self

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.performZOrderCheck()
        }

        let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(emitHeartbeat(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer

        let indexURL = webDir.appendingPathComponent("index.html")
        var comps = URLComponents(url: indexURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if !filtered { items.append(URLQueryItem(name: "nofilter", value: "1")) }
        if clearMode { items.append(URLQueryItem(name: "clear", value: "1")) }
        if !items.isEmpty { comps.queryItems = items }
        let loadURL = comps.url ?? indexURL
        webView.loadFileURL(loadURL, allowingReadAccessTo: webDir)
    }

    // MARK: Window factory

    private static func makeWebSpikeWindow(for screen: NSScreen, webView: WKWebView) -> NSWindow {
        let w = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.hidesOnDeactivate = false
        w.hasShadow = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isReleasedWhenClosed = false
        w.contentView = webView
        w.setFrame(screen.frame, display: false)
        return w
    }

    // MARK: Heartbeat

    @objc func emitHeartbeat(_ sender: Timer) {
        let occ = window.occlusionState.contains(.visible)
        let vis = window.isVisible
        let key = window.isKeyWindow
        let level = window.level.rawValue
        let active = NSApp.isActive
        let win = window.windowNumber
        let line = "OW_WEBSPIKE NATIVE screen=\(screenName) did=\(displayID) win=\(win) occ=\(occ) vis=\(vis) key=\(key) level=\(level) active=\(active) media=\(mediaState)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        webView.requestMediaPlaybackState { [weak self] state in
            switch state {
            case .none: self?.mediaState = "none"
            case .paused: self?.mediaState = "paused"
            case .suspended: self?.mediaState = "suspended"
            case .playing: self?.mediaState = "playing"
            @unknown default: self?.mediaState = "unknown"
            }
        }
    }

    // MARK: Z-order check

    private func performZOrderCheck() {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            FileHandle.standardOutput.write(Data("OW_WEBSPIKE FINDING: CGWindowListCopyWindowInfo returned nil\n".utf8))
            return
        }

        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let selfWindowNumber = window.windowNumber
        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)

        var selfLayer: Int? = nil

        for info in windowList {
            let number = info[kCGWindowNumber as String] as? Int ?? -1
            let layer = info[kCGWindowLayer as String] as? Int ?? Int.max
            let ownerPID = info[kCGWindowOwnerPID as String] as? Int ?? -1

            if number == selfWindowNumber {
                selfLayer = layer
            }

            if ownerPID == selfPID && layer >= iconLevel {
                FileHandle.standardOutput.write(Data("OW_WEBSPIKE FINDING: pid window above icon level win=\(number) layer=\(layer)\n".utf8))
            }
        }

        let layerStr = selfLayer.map { "\($0)" } ?? "unknown"
        let ok = selfLayer.map { $0 < iconLevel } ?? false
        FileHandle.standardOutput.write(Data("OW_WEBSPIKE ZORDER win=\(selfWindowNumber) layer=\(layerStr) ok=\(ok)\n".utf8))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        performZOrderCheck()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        FileHandle.standardOutput.write(Data("OW_WEBSPIKE EVENT=webcontent_terminated\n".utf8))
    }
}
