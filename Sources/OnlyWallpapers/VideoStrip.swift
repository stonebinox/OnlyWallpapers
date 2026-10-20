import AVFoundation
import Foundation

// ow-blz.9: the wallpaper never plays audio, but an audio track in bg.mp4 makes every WebKit seek slow and
// uneven (150 to 450 ms), which limits cross-display sync. The single bg.mp4 slot therefore always holds a
// VIDEO-ONLY file: the video bitstream is passed through untouched (no re-encode), everything else is dropped.

nonisolated struct VideoTrackSummary: Equatable, Sendable {
    var videoTracks: Int
    var otherTracks: Int
    var audioTracks: Int
}

nonisolated struct VideoStripStats: Sendable {
    var audioTracksRemoved: Int
    var otherTracksRemoved: Int = 0
    var bytesIn: Int
    var bytesOut: Int
    var ms: Int

    // The strip=done log fields, shared by the launch migration and the choose path.
    var logFields: String {
        "audio_tracks_removed=\(audioTracksRemoved) other_tracks_removed=\(otherTracksRemoved) bytes_in=\(bytesIn) bytes_out=\(bytesOut) ms=\(ms)"
    }
}

nonisolated struct RemovedTracks: Sendable {
    var audio: Int
    var other: Int
}

nonisolated struct VideoStripError: LocalizedError {
    let reason: String
    // True when the export was still running after the cancel grace period: it may still write its partial, so the
    // caller must NOT delete that file (cleanStalePartials removes it on the next operation or launch).
    var exportStillRunning: Bool = false
    var errorDescription: String? { reason }
}

// The error a stripper throws after its bounded export timed out.
nonisolated func stripTimeoutError(stopped: Bool) -> VideoStripError {
    VideoStripError(reason: stopped ? "strip timed out (export cancelled)" : "strip timed out (export did not stop)",
                    exportStillRunning: !stopped)
}

// Removes a failed operation's partial unless the error says an export may still be writing it; that file is left for
// cleanStalePartials and the decision is logged.
nonisolated func discardPartial(_ url: URL, after error: Error) {
    if (error as? VideoStripError)?.exportStillRunning == true {
        videoLog("partial=left reason=export-still-running file=\(url.lastPathComponent)")
    } else {
        try? FileManager.default.removeItem(at: url)
    }
}

// A stripper writes a video-only copy of `src` to `dst` (which does not exist yet). Injectable so the
// failure fallback can be tested.
typealias VideoStripper = @Sendable (_ src: URL, _ dst: URL) throws -> VideoStripStats

// One writer of the bg.mp4 slot at a time (choose-video copy and the launch migration both run off the main thread).
nonisolated let videoSlotLock = NSLock()

nonisolated func videoLog(_ line: String) {
    FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_VIDEO \(line)\n".utf8))
}

private nonisolated final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

struct BoundedResult<T: Sendable>: Sendable {
    var value: T
    var timedOut: Bool
    // False only when the body was still running after the cancel grace period (it may still touch its outputs).
    var stopped: Bool
}

// Runs an async body from synchronous, non-main code. On timeout the body is cancelled (Task cancel plus `cancel`, e.g.
// AVAssetExportSession.cancelExport) and then WAITED FOR, bounded by `graceSec`, so a timed out body is stopped before the
// caller touches any file it could write. After a timeout `value` is always `fallback`.
nonisolated func runWithTimeout<T: Sendable>(_ fallback: T, timeoutSec: Double, graceSec: Double = 30,
                                             cancel: (@Sendable () -> Void)? = nil,
                                             _ body: @escaping @Sendable () async -> T) -> BoundedResult<T> {
    let box = Box(fallback)
    let sem = DispatchSemaphore(value: 0)
    let task = Task.detached {
        box.value = await body()
        sem.signal()
    }
    if sem.wait(timeout: .now() + timeoutSec) == .success {
        return BoundedResult(value: box.value, timedOut: false, stopped: true)
    }
    task.cancel()
    cancel?()
    let stopped = sem.wait(timeout: .now() + graceSec) == .success
    return BoundedResult(value: fallback, timedOut: true, stopped: stopped)
}

private nonisolated func blocking<T: Sendable>(_ fallback: T, timeoutSec: Double, _ body: @escaping @Sendable () async -> T) -> T {
    runWithTimeout(fallback, timeoutSec: timeoutSec, body).value
}

// Every strip or copy writes its own uniquely named partial, so an export that outlives its operation can never write a
// path a later operation uses.
nonisolated func uniquePartialURL(in dir: URL) -> URL {
    dir.appendingPathComponent("bg.mp4.\(UUID().uuidString).partial")
}

// Removes leftovers of crashed or abandoned operations: the legacy bg.mp4.partial and bg.mp4.<uuid>.partial.
nonisolated func cleanStalePartials(in dir: URL) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
    for n in names where n.hasPrefix("bg.mp4.") && n.hasSuffix(".partial") {
        try? fm.removeItem(at: dir.appendingPathComponent(n))
    }
}

// The slot's .partial file has no .mp4 extension, so name the type explicitly.
nonisolated func mp4Asset(_ url: URL) -> AVURLAsset {
    AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
}

nonisolated func summarizeTracks(url: URL) -> VideoTrackSummary? {
    blocking(nil as VideoTrackSummary?, timeoutSec: 30) {
        let asset = mp4Asset(url)
        guard let tracks = try? await asset.load(.tracks) else { return nil }
        let video = tracks.filter { $0.mediaType == .video }.count
        let audio = tracks.filter { $0.mediaType == .audio }.count
        return VideoTrackSummary(videoTracks: video, otherTracks: tracks.count - video, audioTracks: audio)
    }
}

// Passthrough export of the first video track only (AVMutableComposition + AVAssetExportPresetPassthrough):
// no decode or encode, the compressed samples are rewritten into a new .mp4.
nonisolated func stripToVideoOnly(src: URL, dst: URL) throws -> VideoStripStats {
    try stripToVideoOnly(src: src, dst: dst, timeoutSec: 60, graceSec: 30)
}

nonisolated func stripToVideoOnly(src: URL, dst: URL, timeoutSec: Double, graceSec: Double) throws -> VideoStripStats {
    let started = Date()
    let session = Box<AVAssetExportSession?>(nil)
    let sessionLock = NSLock()
    let bounded = runWithTimeout(Result<RemovedTracks, VideoStripError>.failure(VideoStripError(reason: "timeout")), timeoutSec: timeoutSec, graceSec: graceSec, cancel: {
        sessionLock.lock(); defer { sessionLock.unlock() }
        session.value?.cancelExport()
    }) { () async -> Result<RemovedTracks, VideoStripError> in
        let asset = mp4Asset(src)
        do {
            let tracks = try await asset.load(.tracks)
            guard let video = tracks.first(where: { $0.mediaType == .video }) else {
                return .failure(VideoStripError(reason: "no video track"))
            }
            let range = try await video.load(.timeRange)
            let transform = try await video.load(.preferredTransform)
            let size = try await video.load(.naturalSize)
            let comp = AVMutableComposition()
            guard let compTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return .failure(VideoStripError(reason: "cannot add composition track"))
            }
            try compTrack.insertTimeRange(range, of: video, at: .zero)
            compTrack.preferredTransform = transform
            comp.naturalSize = size
            guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
                return .failure(VideoStripError(reason: "no passthrough export session"))
            }
            sessionLock.withLock { session.value = export }
            if Task.isCancelled { return .failure(VideoStripError(reason: "cancelled")) }
            export.outputURL = dst
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true
            await export.export()
            if export.status != .completed {
                return .failure(VideoStripError(reason: export.error?.localizedDescription ?? "export status \(export.status.rawValue)"))
            }
            let audioRemoved = tracks.filter { $0.mediaType == .audio }.count
            return .success(RemovedTracks(audio: audioRemoved, other: tracks.count - 1 - audioRemoved))
        } catch {
            return .failure(VideoStripError(reason: error.localizedDescription))
        }
    }
    let removed = bounded.value
    switch removed {
    case .failure(let e):
        // A body that is still running after the grace period may still write dst: leave it for cleanStalePartials.
        if bounded.timedOut {
            if bounded.stopped { try? FileManager.default.removeItem(at: dst) }
            throw stripTimeoutError(stopped: bounded.stopped)
        }
        throw e
    case .success(let removedTracks):
        let inSize = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int) ?? 0
        let outSize = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
        return VideoStripStats(audioTracksRemoved: removedTracks.audio, otherTracksRemoved: removedTracks.other, bytesIn: inSize, bytesOut: outSize, ms: Int(Date().timeIntervalSince(started) * 1000))
    }
}

// The stripped file must be exactly one video track, nothing else, with the same duration as the source's video track
// (within one frame; the container duration of the source can be longer because of the audio).
nonisolated func validateStripped(src: URL, out: URL) -> String? {
    guard let s = summarizeTracks(url: out) else { return "output unreadable" }
    if s.videoTracks != 1 || s.otherTracks != 0 { return "output tracks video=\(s.videoTracks) other=\(s.otherTracks)" }
    guard let a = firstVideoTrackTiming(src), let b = firstVideoTrackTiming(out) else { return "cannot read video duration" }
    let frame = 1.0 / Double(max(a.fps, 1))
    if abs(a.durationSec - b.durationSec) > frame { return "duration drift \(a.durationSec) vs \(b.durationSec)" }
    return nil
}

nonisolated func firstVideoTrackTiming(_ url: URL) -> (durationSec: Double, fps: Float)? {
    blocking(nil as (durationSec: Double, fps: Float)?, timeoutSec: 30) {
        let asset = mp4Asset(url)
        guard let tracks = try? await asset.load(.tracks), let v = tracks.first(where: { $0.mediaType == .video }),
              let range = try? await v.load(.timeRange), let fps = try? await v.load(.nominalFrameRate) else { return nil }
        let d = CMTimeGetSeconds(range.duration)
        return d.isFinite && d > 0 ? (d, fps > 0 ? fps : 24) : nil
    }
}

// Atomically puts `partialURL` into the slot (replace when it exists, move on first pick).
nonisolated func installIntoSlot(partialURL: URL, slotURL: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: slotURL.path) {
        _ = try fm.replaceItemAt(slotURL, withItemAt: partialURL)
    } else {
        try fm.moveItem(at: partialURL, to: slotURL)
    }
}

nonisolated enum MigrationOutcome: String, Sendable { case stripped, skipped, failed }

// One-time launch migration: an existing bg.mp4 that still carries audio (or any non-video track) is rewritten video-only.
// Idempotent: a stripped slot has no such track, so later launches skip.
nonisolated func migrateSlotToVideoOnly(assetsDir: URL, stripper: VideoStripper = stripToVideoOnly) -> MigrationOutcome {
    videoSlotLock.lock()
    defer { videoSlotLock.unlock() }
    let fm = FileManager.default
    let slotURL = assetsDir.appendingPathComponent("bg.mp4")
    cleanStalePartials(in: assetsDir)
    let partialURL = uniquePartialURL(in: assetsDir)
    guard fm.fileExists(atPath: slotURL.path), let summary = summarizeTracks(url: slotURL),
          summary.videoTracks >= 1, summary.otherTracks > 0 else {
        videoLog("migrate=skipped")
        return .skipped
    }
    let slotSize = (try? fm.attributesOfItem(atPath: slotURL.path)[.size] as? Int) ?? 0
    if let fsAttrs = try? fm.attributesOfFileSystem(forPath: assetsDir.path),
       let free = fsAttrs[.systemFreeSize] as? Int, free < slotSize + max(slotSize, 10 * 1024 * 1024) {
        videoLog("migrate=failed reason=low-disk-space")
        return .failed
    }
    try? fm.removeItem(at: partialURL)
    do {
        let stats = try stripper(slotURL, partialURL)
        if let bad = validateStripped(src: slotURL, out: partialURL) { throw VideoStripError(reason: bad) }
        try installIntoSlot(partialURL: partialURL, slotURL: slotURL)
        videoLog("strip=done \(stats.logFields)")
        videoLog("migrate=stripped")
        return .stripped
    } catch {
        discardPartial(partialURL, after: error)
        videoLog("migrate=failed reason=\(error.localizedDescription)")
        return .failed
    }
}
