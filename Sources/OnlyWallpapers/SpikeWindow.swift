// SPIKE: This file is a diagnostic spike for desktop-layer window placement.
// It is the ONLY file allowed to reference NSWindow directly.
// Remove or gate behind a compile flag before shipping.

import AppKit
import QuartzCore
import CoreGraphics

// MARK: - Spike window factory

// makeSpikeWindowAndShow creates a spike window for the given screen, shows it,
// and returns it as AnyObject so callers outside this file need not name the spike type.
func makeSpikeWindowAndShow(for screen: NSScreen) -> AnyObject {
    let w = makeSpikeWindow(for: screen)
    w.orderFrontRegardless()
    return w
}

func makeSpikeWindow(for screen: NSScreen) -> NSWindow {
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
    w.isOpaque = true
    w.backgroundColor = .black
    w.isReleasedWhenClosed = false
    let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    let probe = ProbeView(frame: screen.frame, screenName: screen.localizedName, displayID: displayID)
    w.contentView = probe
    probe.spikeWindow = w
    w.setFrame(screen.frame, display: false)
    return w
}

// MARK: - ProbeView

final class ProbeView: NSView {

    // MARK: Properties

    private let screenName: String
    private let displayID: UInt32

    var frameCount: Int = 0
    var drawCount: Int = 0
    var caValue: Double = 0.0
    var zorderOK: String = "unknown"
    var lastHeartbeatTime: CFTimeInterval = 0

    weak var spikeWindow: NSWindow?

    private var sublayer: CALayer?

    // MARK: Init

    init(frame: NSRect, screenName: String, displayID: UInt32) {
        self.screenName = screenName
        self.displayID = displayID
        super.init(frame: frame)
        setupCALayer()
        scheduleZOrderCheck()
        // Start the tick timer immediately; it is added to the run loop so
        // it fires even before the view is on screen.
        startTickTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented for ProbeView")
    }

    // MARK: NSView overrides

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1

        NSColor.magenta.setFill()
        dirtyRect.fill()

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: now)

        let text = "frame: \(frameCount)  draws: \(drawCount)  ca: \(String(format: "%.1f", caValue))\n\(timestamp)\n\(screenName)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 80, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()
        let x = (bounds.width - textSize.width) / 2
        let y = (bounds.height - textSize.height) / 2
        attrStr.draw(at: NSPoint(x: x, y: y))
    }

    // MARK: Tick timer

    private func startTickTimer() {
        guard tickTimer == nil else { return }
        // Use a Timer added to RunLoop.main in .common mode as the tick driver.
        // This fires regardless of whether AppKit considers the desktop-layer
        // window "on screen", unlike CADisplayLink which requires the view to
        // be visible to a display.
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private var tickTimer: Timer?

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    @objc private func tick(_ sender: Any) {
        frameCount += 1
        caValue = Double(sublayer?.presentation()?.position.x ?? 0.0)
        needsDisplay = true

        let now = CACurrentMediaTime()
        if now - lastHeartbeatTime > 1.0 {
            lastHeartbeatTime = now
            emitHeartbeat()
        }
    }

    // MARK: CA layer probe

    private func setupCALayer() {
        wantsLayer = true

        let sub = CALayer()
        sub.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        sub.backgroundColor = NSColor.magenta.cgColor

        // Animate position.x linearly from 0 to 100000 over 600 seconds.
        // A single long-period monotonic animation prevents aliasing when
        // sampled at ~1s intervals: a healthy render server yields steadily
        // increasing ca= values; a frozen render server yields a flat value.
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = 0.0
        anim.toValue = 100000.0
        anim.duration = 600.0
        anim.repeatCount = 1
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        sub.add(anim, forKey: "positionProbe")

        layer?.addSublayer(sub)
        sublayer = sub
    }

    // MARK: Z-order check

    private func scheduleZOrderCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.performZOrderCheck()
        }
    }

    private func performZOrderCheck() {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            zorderOK = "unknown"
            writeOut("OW_SPIKE FINDING: CGWindowListCopyWindowInfo returned nil; cannot determine self layer\n")
            writeOut("OW_SPIKE STARTUP screen=\(screenName) self_layer=unknown finder_icon_layer=unknown\n")
            return
        }

        guard let win = spikeWindow else {
            zorderOK = "unknown"
            writeOut("OW_SPIKE FINDING: spikeWindow is nil; cannot determine self layer\n")
            writeOut("OW_SPIKE STARTUP screen=\(screenName) self_layer=unknown finder_icon_layer=unknown\n")
            return
        }

        let selfWindowNumber = win.windowNumber
        var selfLayer: Int? = nil
        var finderIconLayer: Int? = nil

        for info in windowList {
            let number = info[kCGWindowNumber as String] as? Int ?? -1
            let layer = info[kCGWindowLayer as String] as? Int ?? Int.max
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""

            if number == selfWindowNumber {
                selfLayer = layer
            }

            // Best-effort: detect Finder desktop-icon layer for informational logging only.
            if owner == "Finder" && layer == iconLevel && finderIconLayer == nil {
                finderIconLayer = layer
            }
        }

        let selfLayerStr = selfLayer.map { "\($0)" } ?? "unknown"
        let finderIconLayerStr = finderIconLayer.map { "\($0)" } ?? "unknown"

        if let sl = selfLayer {
            zorderOK = sl < iconLevel ? "true" : "false"
        } else {
            zorderOK = "unknown"
            writeOut("OW_SPIKE FINDING: self window not found on screen (windowNumber=\(selfWindowNumber)); cannot determine z-order\n")
        }

        writeOut("OW_SPIKE STARTUP screen=\(screenName) self_layer=\(selfLayerStr) finder_icon_layer=\(finderIconLayerStr)\n")
    }

    // MARK: Heartbeat

    private func emitHeartbeat() {
        let occ = spikeWindow?.occlusionState.contains(.visible) ?? false
        let vis = spikeWindow?.isVisible ?? false
        let level = spikeWindow?.level.rawValue ?? -1
        let caStr = String(format: "%.1f", caValue)
        let line = "OW_SPIKE screen=\(screenName) did=\(displayID) driver=\(frameCount) draws=\(drawCount) ca=\(caStr) occ=\(occ) vis=\(vis) level=\(level) zorder_ok=\(zorderOK)\n"
        writeOut(line)
    }

    // MARK: Helpers

    private func writeOut(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }
}
