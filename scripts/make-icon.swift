// make-icon.swift: procedural app icon generator for OnlyWallpapers (ow-t4r.6).
//
// Usage:
//   swift scripts/make-icon.swift <variant> <out.png> [size]      one PNG (default 1024)
//   swift scripts/make-icon.swift all <outdir>                    every variant at 1024/64/32
//   swift scripts/make-icon.swift icns <variant> <out.icns>       full iconset via iconutil
//
// Variants: dusk (landscape on a monitor), aurora (layered waves), storm (cloud + bolt).
// Everything is drawn in a 1024 design space with the standard macOS icon grid:
// an 824pt Apple-style squircle body (radius ~185) inset 100pt, soft drop shadow, inner highlight.

import AppKit
import CoreGraphics
import Foundation

let variants = ["dusk", "aurora", "storm"]

// MARK: helpers

func C(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

func grad(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: rgb, colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

func linear(_ c: CGContext, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ c: CGContext, _ g: CGGradient, center: CGPoint, radius: CGFloat) {
    c.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// macOS continuous-curvature rounded rect (Apple icon squircle). Each corner is the
/// standard 3-segment bezier profile, expressed in units of the radius r.
func squircle(_ rect: CGRect, radius r: CGFloat = 185) -> CGPath {
    // top-right profile as (a, b): a = distance left of the right edge, b = distance below the top edge
    let k: [[(CGFloat, CGFloat)]] = [
        [(1.08849296, 0), (0.86840694, 0), (0.63149379, 0.07491461)],
        [(0.37282383, 0.16905956), (0.16905956, 0.37282383), (0.07491461, 0.63149379)],
        [(0, 0.86840694), (0, 1.08849296), (0, 1.52866483)]]
    let e: CGFloat = 1.52866483
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX + e * r, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - e * r, y: rect.minY))
    func corner(_ map: (CGFloat, CGFloat) -> CGPoint) {
        for s in k {
            p.addCurve(to: map(s[2].0, s[2].1), control1: map(s[0].0, s[0].1), control2: map(s[1].0, s[1].1))
        }
    }
    corner { a, b in CGPoint(x: rect.maxX - a * r, y: rect.minY + b * r) }
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - e * r))
    corner { a, b in CGPoint(x: rect.maxX - b * r, y: rect.maxY - a * r) }
    p.addLine(to: CGPoint(x: rect.minX + e * r, y: rect.maxY))
    corner { a, b in CGPoint(x: rect.minX + a * r, y: rect.maxY - b * r) }
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + e * r))
    corner { a, b in CGPoint(x: rect.minX + b * r, y: rect.minY + a * r) }
    p.closeSubpath()
    return p
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Wavy horizon path from x0..x1, closed down to `bottom`.
func wave(_ x0: CGFloat, _ x1: CGFloat, bottom: CGFloat,
          _ f: (CGFloat) -> CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x0, y: bottom))
    var x = x0
    while x <= x1 { p.addLine(to: CGPoint(x: x, y: f(x))); x += 4 }
    p.addLine(to: CGPoint(x: x1, y: bottom))
    p.closeSubpath()
    return p
}

func curve(_ x0: CGFloat, _ x1: CGFloat, _ f: (CGFloat) -> CGFloat) -> CGPath {
    let p = CGMutablePath()
    var x = x0
    p.move(to: CGPoint(x: x, y: f(x)))
    while x <= x1 { p.addLine(to: CGPoint(x: x, y: f(x))); x += 4 }
    return p
}

// MARK: variants (design space 1024, y grows downward)

var S: CGFloat = 1  // device scale, for shadow values (CG shadows ignore the CTM)

func glow(_ c: CGContext, _ color: CGColor, blur: CGFloat, dy: CGFloat = 0) {
    c.setShadow(offset: CGSize(width: 0, height: -dy * S), blur: blur * S, color: color)
}

func drawDusk(_ c: CGContext) {
    // Backdrop: indigo night with a warm bloom behind the screen.
    linear(c, grad([(0, C(0x2a1f70)), (0.55, C(0x1a1250)), (1, C(0x0d0a2e))]),
           from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))
    radial(c, grad([(0, C(0xff8a5c, 0.45)), (1, C(0xff8a5c, 0))]),
           center: CGPoint(x: 512, y: 560), radius: 520)

    // Monitor.
    let bezel = CGRect(x: 134, y: 222, width: 756, height: 504)
    // stand
    c.saveGState()
    c.addPath(rounded(CGRect(x: 468, y: 712, width: 88, height: 70), 10))
    c.clip()
    linear(c, grad([(0, C(0x2b2557)), (1, C(0x120e33))]), from: CGPoint(x: 0, y: 712), to: CGPoint(x: 0, y: 782))
    c.restoreGState()
    c.saveGState()
    c.addPath(rounded(CGRect(x: 392, y: 764, width: 240, height: 26), 13))
    c.clip()
    linear(c, grad([(0, C(0x4a427e)), (1, C(0x1b1545))]), from: CGPoint(x: 0, y: 764), to: CGPoint(x: 0, y: 790))
    c.restoreGState()

    // bezel body with drop shadow
    c.saveGState()
    glow(c, C(0x000000, 0.55), blur: 30, dy: 14)
    c.addPath(rounded(bezel, 46))
    c.setFillColor(C(0x15112f))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(rounded(bezel, 46))
    c.clip()
    linear(c, grad([(0, C(0x4b4380)), (0.12, C(0x2a2358)), (1, C(0x120e30))]),
           from: CGPoint(x: 0, y: bezel.minY), to: CGPoint(x: 0, y: bezel.maxY))
    c.restoreGState()

    // Screen.
    let screen = bezel.insetBy(dx: 18, dy: 18)
    c.saveGState()
    c.addPath(rounded(screen, 30))
    c.clip()
    let top = screen.minY, bot = screen.maxY
    let hor = screen.minY + screen.height * 0.64
    linear(c, grad([(0, C(0x1d1560)), (0.35, C(0x6a2f98)), (0.62, C(0xe8557a)),
                    (0.80, C(0xff9a5a)), (1, C(0xffd08a))]),
           from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: hor + 20))
    // stars
    let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (230, 262, 3.2, 0.9), (330, 300, 2.2, 0.7), (420, 252, 2.6, 0.8), (640, 276, 2.4, 0.7),
        (760, 250, 3.4, 0.95), (830, 330, 2.2, 0.6), (270, 350, 1.8, 0.5), (560, 240, 1.8, 0.6)]
    for (x, y, r, a) in stars {
        c.setFillColor(C(0xffffff, a))
        c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    // sun: bloom and disc
    let sun = CGPoint(x: 590, y: hor - 28)
    radial(c, grad([(0, C(0xfff0c8, 0.95)), (0.18, C(0xffc06a, 0.65)), (0.5, C(0xff7a5a, 0.22)), (1, C(0xff7a5a, 0))]),
           center: sun, radius: 330)
    c.setFillColor(C(0xfff4d6))
    c.fillEllipse(in: CGRect(x: sun.x - 46, y: sun.y - 46, width: 92, height: 92))
    // hills, far to near
    let layers: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, UInt32, UInt32)] = [
        // base offset, amp1, freq1, phase, amp2, top color, bottom color
        (-8, 34, 0.0085, 0.4, 12, 0xc0507f, 0x8a3f86),
        (30, 42, 0.0070, 2.1, 14, 0x7d3a8f, 0x4c2a78),
        (72, 38, 0.0095, 4.0, 16, 0x3f2a76, 0x251a5a),
        (118, 34, 0.0075, 1.0, 12, 0x1d1450, 0x120c38)]
    for (off, a1, f1, ph, a2, ct, cb) in layers {
        let path = wave(screen.minX, screen.maxX, bottom: bot) { x in
            hor + off - a1 * sin(x * f1 + ph) - a2 * sin(x * f1 * 2.7 + ph * 1.7)
        }
        c.saveGState()
        c.addPath(path)
        c.clip()
        linear(c, grad([(0, C(ct)), (1, C(cb))]), from: CGPoint(x: 0, y: hor + off - 60), to: CGPoint(x: 0, y: bot))
        c.restoreGState()
    }
    // glass reflection
    let refl = CGMutablePath()
    refl.move(to: CGPoint(x: screen.minX, y: top))
    refl.addLine(to: CGPoint(x: screen.minX + 420, y: top))
    refl.addLine(to: CGPoint(x: screen.minX + 130, y: bot))
    refl.addLine(to: CGPoint(x: screen.minX, y: bot))
    refl.closeSubpath()
    c.addPath(refl)
    c.clip()
    linear(c, grad([(0, C(0xffffff, 0.14)), (1, C(0xffffff, 0))]),
           from: CGPoint(x: screen.minX, y: top), to: CGPoint(x: screen.minX + 260, y: bot))
    c.restoreGState()
    // screen edge
    c.addPath(rounded(screen, 30))
    c.setStrokeColor(C(0x000000, 0.45))
    c.setLineWidth(3)
    c.strokePath()
}

func drawAurora(_ c: CGContext) {
    linear(c, grad([(0, C(0x07102e)), (0.5, C(0x12154a)), (1, C(0x070a22))]),
           from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))
    radial(c, grad([(0, C(0x3de0c0, 0.30)), (1, C(0x3de0c0, 0))]), center: CGPoint(x: 330, y: 330), radius: 460)
    radial(c, grad([(0, C(0xa14bff, 0.28)), (1, C(0xa14bff, 0))]), center: CGPoint(x: 760, y: 280), radius: 420)
    // sparse stars
    let stars: [(CGFloat, CGFloat, CGFloat)] = [(250, 230, 2.6), (420, 190, 2), (580, 250, 3), (730, 200, 2.2), (830, 300, 2), (330, 310, 1.8)]
    for (x, y, r) in stars {
        c.setFillColor(C(0xffffff, 0.75))
        c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    // layered waves, back to front
    struct W { let base: CGFloat; let a: CGFloat; let crest: UInt32; let rim: UInt32; let drift: CGFloat }
    // Bands share one flow (same frequency and phase, tiny drift) and are spaced wider than
    // their amplitude difference, so no band's crest ever reaches the band above it.
    let ws = [
        W(base: 392, a: 44, crest: 0x37f2c4, rim: 0xc8fff0, drift: 0.00),
        W(base: 490, a: 46, crest: 0x2ab4ff, rim: 0xbfe9ff, drift: 0.12),
        W(base: 588, a: 48, crest: 0x5b63ff, rim: 0xcfd2ff, drift: 0.24),
        W(base: 686, a: 48, crest: 0xa650ff, rim: 0xe6c8ff, drift: 0.36),
        W(base: 784, a: 46, crest: 0xff5fc4, rim: 0xffd0ee, drift: 0.48)]
    for w in ws {
        let fy: (CGFloat) -> CGFloat = { x in
            let u = x * 0.0062 + 0.3 + w.drift
            return w.base - w.a * sin(u) - w.a * 0.30 * sin(u * 2.1 + 0.8)
        }
        let body = wave(80, 944, bottom: 960, fy)
        c.saveGState()
        c.addPath(body)
        c.clip()
        linear(c, grad([(0, C(w.crest, 0.95)), (0.45, C(w.crest, 0.35)), (1, C(0x070a22, 0.92))]),
               from: CGPoint(x: 0, y: w.base - w.a - 20), to: CGPoint(x: 0, y: w.base + 190))
        c.restoreGState()
        // glowing rim
        c.saveGState()
        glow(c, C(w.crest, 0.95), blur: 22)
        c.addPath(curve(80, 944, fy))
        c.setStrokeColor(C(w.rim, 0.9))
        c.setLineWidth(5)
        c.setLineCap(.round)
        c.strokePath()
        c.restoreGState()
    }
}

func drawStorm(_ c: CGContext) {
    linear(c, grad([(0, C(0x23205f)), (0.55, C(0x2e2468)), (1, C(0x120f38))]),
           from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))
    // lightning glow lighting the sky from below the cloud
    radial(c, grad([(0, C(0xffd27a, 0.55)), (0.4, C(0xff8a5c, 0.2)), (1, C(0xff8a5c, 0))]),
           center: CGPoint(x: 520, y: 600), radius: 470)

    // rain streaks
    c.setLineCap(.round)
    let rain: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (262, 560, 74, 0.55), (330, 640, 90, 0.7), (230, 700, 70, 0.4), (410, 730, 80, 0.5),
        (640, 570, 80, 0.6), (718, 660, 92, 0.75), (790, 560, 66, 0.45), (690, 770, 70, 0.4),
        (806, 720, 78, 0.55), (300, 790, 62, 0.35)]
    for (x, y, len, a) in rain {
        c.saveGState()
        glow(c, C(0x7ad0ff, 0.6), blur: 8)
        c.setStrokeColor(C(0xbfe6ff, a))
        c.setLineWidth(9)
        c.move(to: CGPoint(x: x, y: y))
        c.addLine(to: CGPoint(x: x - len * 0.30, y: y + len))
        c.strokePath()
        c.restoreGState()
    }

    // cloud
    let cloud = CGMutablePath()
    cloud.addRoundedRect(in: CGRect(x: 214, y: 388, width: 596, height: 136), cornerWidth: 68, cornerHeight: 68)
    for (cx, cy, r) in [(372.0, 392.0, 112.0), (532.0, 340.0, 150.0), (690.0, 398.0, 106.0)] as [(CGFloat, CGFloat, CGFloat)] {
        cloud.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    }
    c.saveGState()
    glow(c, C(0x000000, 0.4), blur: 30, dy: 16)
    c.addPath(cloud)
    c.setFillColor(C(0x4a3f96))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(cloud)
    c.clip()
    linear(c, grad([(0, C(0xd9d2ff)), (0.45, C(0x9d90e6)), (1, C(0x5a4cae))]),
           from: CGPoint(x: 0, y: 190), to: CGPoint(x: 0, y: 524))
    // warm underlight from the bolt
    radial(c, grad([(0, C(0xffc870, 0.7)), (1, C(0xffc870, 0))]), center: CGPoint(x: 530, y: 540), radius: 250)
    c.restoreGState()

    // bolt
    let bolt = CGMutablePath()
    let pts: [(CGFloat, CGFloat)] = [(584, 470), (430, 690), (516, 690), (448, 872), (660, 626), (562, 626), (634, 470)]
    bolt.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for p in pts.dropFirst() { bolt.addLine(to: CGPoint(x: p.0, y: p.1)) }
    bolt.closeSubpath()
    c.saveGState()
    glow(c, C(0xffb43c, 0.95), blur: 46)
    c.addPath(bolt)
    c.setFillColor(C(0xffd36b))
    c.setLineJoin(.round)
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(bolt)
    c.clip()
    linear(c, grad([(0, C(0xffffff)), (0.5, C(0xfff0b0)), (1, C(0xffc24a))]),
           from: CGPoint(x: 0, y: 470), to: CGPoint(x: 0, y: 872))
    c.restoreGState()
}

// MARK: icon frame

func render(variant: String, size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    S = CGFloat(size) / 1024
    // design space: y down
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: S, y: -S)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = squircle(body)

    // drop shadows
    ctx.saveGState()
    glow(ctx, C(0x000000, 0.34), blur: 38, dy: 20)
    ctx.addPath(path); ctx.setFillColor(C(0x101030)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    glow(ctx, C(0x000000, 0.30), blur: 6, dy: 4)
    ctx.addPath(path); ctx.setFillColor(C(0x101030)); ctx.fillPath()
    ctx.restoreGState()

    // art
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    switch variant {
    case "dusk": drawDusk(ctx)
    case "aurora": drawAurora(ctx)
    case "storm": drawStorm(ctx)
    default: fputs("unknown variant \(variant)\n", stderr); exit(2)
    }
    // soft top sheen
    linear(ctx, grad([(0, C(0xffffff, 0.08)), (1, C(0xffffff, 0))]),
           from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 460))
    // gentle bottom falloff
    linear(ctx, grad([(0, C(0x000000, 0)), (1, C(0x000000, 0.20))]),
           from: CGPoint(x: 0, y: 700), to: CGPoint(x: 0, y: 924))
    ctx.restoreGState()

    // inner edge highlight (bright on top, dark at the bottom)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.addPath(path)
    ctx.clip()  // keep only the inner half of the stroke
    linear(ctx, grad([(0, C(0xffffff, 0.60)), (0.4, C(0xffffff, 0.10)), (0.75, C(0x000000, 0.0)), (1, C(0x000000, 0.30))]),
           from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))
    ctx.restoreGState()
    return ctx
}

func writePNG(_ ctx: CGContext, to path: String) {
    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fputs("cannot write \(path)\n", stderr); exit(1)
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fputs("finalize failed \(path)\n", stderr); exit(1) }
}

func buildICNS(variant: String, out: String) {
    let tmp = NSTemporaryDirectory() + "ow-icon-\(getpid()).iconset"
    try? FileManager.default.removeItem(atPath: tmp)
    try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        writePNG(render(variant: variant, size: base), to: "\(tmp)/icon_\(base)x\(base).png")
        writePNG(render(variant: variant, size: base * 2), to: "\(tmp)/icon_\(base)x\(base)@2x.png")
    }
    try? FileManager.default.createDirectory(
        at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", tmp, "-o", out]
    try! p.run(); p.waitUntilExit()
    try? FileManager.default.removeItem(atPath: tmp)
    if p.terminationStatus != 0 { fputs("iconutil failed\n", stderr); exit(1) }
}

// MARK: main

let args = Array(CommandLine.arguments.dropFirst())
func usage() -> Never {
    fputs("usage: make-icon.swift <variant> <out.png> [size] | all <outdir> | icns <variant> <out.icns>\n"
          + "variants: \(variants.joined(separator: ", "))\n", stderr)
    exit(64)
}
guard let cmd = args.first else { usage() }
switch cmd {
case "all":
    guard args.count == 2 else { usage() }
    for v in variants {
        writePNG(render(variant: v, size: 1024), to: "\(args[1])/\(v).png")
        writePNG(render(variant: v, size: 64), to: "\(args[1])/\(v)-64.png")
        writePNG(render(variant: v, size: 32), to: "\(args[1])/\(v)-32.png")
    }
case "icns":
    guard args.count == 3, variants.contains(args[1]) else { usage() }
    buildICNS(variant: args[1], out: args[2])
default:
    guard args.count >= 2, variants.contains(cmd) else { usage() }
    writePNG(render(variant: cmd, size: args.count > 2 ? Int(args[2]) ?? 1024 : 1024), to: args[1])
}
