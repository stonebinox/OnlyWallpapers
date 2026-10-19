import AVFoundation
import Foundation

// Shared wallpaper session (ow-blz.5, ow-blz.6). One tuple per app run and per video source,
// injected into every web view so all displays derive the same video target time and the same
// lightning schedule from the wall clock.
struct VideoSession: Equatable {
    // Wall-clock ms (Date.now scale) at which the current source started playing at t=0.
    let epochMs: Int64
    // Bumps on every Choose video.
    let sourceRev: Int
    // Probed natively once per source; 0 when the probe failed (JS then falls back to the element).
    let durationSec: Double
    // Random per app run (fixed in test mode). Drives the stateless lightning schedule.
    let seed: UInt32

    // JSON object literal, safe to splice into JS. Non-finite or negative durations become 0.
    var jsLiteral: String {
        let dur = (durationSec.isFinite && durationSec > 0) ? durationSec : 0
        return "{\"epochMs\":\(epochMs),\"sourceRev\":\(sourceRev),\"durationSec\":\(dur),\"seed\":\(seed)}"
    }

    var userScriptSource: String { "window.__wallpaperSession = \(jsLiteral);" }

    // Probe-failure path: the first reported element duration becomes the ONE shared duration. Only
    // adopted while no duration is set and the report is usable, so a later report never overrides it.
    func adoptingDuration(_ reported: Double) -> VideoSession {
        guard durationSec <= 0, reported.isFinite, reported > 0 else { return self }
        return VideoSession(epochMs: epochMs, sourceRev: sourceRev, durationSec: reported, seed: seed)
    }

    func nextSource(epochMs: Int64, durationSec: Double) -> VideoSession {
        VideoSession(epochMs: epochMs, sourceRev: sourceRev + 1, durationSec: durationSec, seed: seed)
    }
}

func nowEpochMs() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
}

// Fixed seed in test mode so every window and every run agrees; random per run otherwise.
func makeSessionSeed(env: [String: String]) -> UInt32 {
    if let s = env["OW_SYNC_SEED"], let v = UInt32(s) { return v }
    if env["OW_SYNC_TEST"] == "1" || env["OW_WGT_TEST"] == "1" { return 20260518 }
    return UInt32.random(in: 0...UInt32.max)
}

// Probes the container duration with AVURLAsset. Blocks the caller briefly (local file, header
// read only). Returns 0 for a missing, unreadable, or indefinite-duration file.
nonisolated func probeDurationSec(url: URL) -> Double {
    // OW_SYNC_TEST hook: force the failure path so the shared-duration adoption can be exercised.
    if ProcessInfo.processInfo.environment["OW_SYNC_TEST_PROBE_FAIL"] == "1" { return 0 }
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    let box = DurationBox()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let asset = AVURLAsset(url: url)
        if let t = try? await asset.load(.duration) {
            let s = CMTimeGetSeconds(t)
            if s.isFinite && s > 0 { box.value = s }
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
    return box.value
}

private nonisolated final class DurationBox: @unchecked Sendable {
    var value: Double = 0
}
