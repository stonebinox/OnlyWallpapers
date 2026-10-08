import Foundation
import CryptoKit

enum AppStorageManager {

    static var seedFailed: Bool = false
    static var testingRootOverride: URL? = nil

    struct FramingConfig {
        var zoom: Double
        var panX: Double
        var panY: Double
    }

    static var currentFraming: FramingConfig = readFraming()

    private static func clampFraming(_ cfg: FramingConfig) -> FramingConfig {
        func cl(_ x: Double, lo: Double, hi: Double, def: Double) -> Double {
            guard x.isFinite else { return def }
            return min(max(x, lo), hi)
        }
        return FramingConfig(
            zoom: cl(cfg.zoom, lo: 1, hi: 2, def: 1),
            panX: cl(cfg.panX, lo: -1, hi: 1, def: 0),
            panY: cl(cfg.panY, lo: -1, hi: 1, def: 0)
        )
    }

    static func readFraming() -> FramingConfig {
        let url = appSupportRoot().appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return FramingConfig(zoom: 1, panX: 0, panY: 0)
        }
        func field(_ key: String, lo: Double, hi: Double, def: Double) -> Double {
            guard let v = obj[key], let n = (v as? NSNumber)?.doubleValue, n.isFinite else { return def }
            return min(max(n, lo), hi)
        }
        return FramingConfig(
            zoom: field("zoom", lo: 1, hi: 2, def: 1),
            panX: field("panX", lo: -1, hi: 1, def: 0),
            panY: field("panY", lo: -1, hi: 1, def: 0)
        )
    }

    // MARK: - Merge-based config.json helpers

    private static func readConfigDict() -> [String: Any] {
        let url = appSupportRoot().appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    @discardableResult
    private static func writeConfigDict(_ dict: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return false }
        let url = appSupportRoot().appendingPathComponent("config.json")
        let partial = appSupportRoot().appendingPathComponent("config.json.partial")
        do {
            try? FileManager.default.createDirectory(at: appSupportRoot(), withIntermediateDirectories: true)
            try data.write(to: partial, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: url)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return false
        }
    }

    @discardableResult
    static func writeFraming(_ cfg: FramingConfig) -> Bool {
        let clamped = clampFraming(cfg)
        let r2: (Double) -> Double = { ($0 * 100).rounded() / 100 }
        var obj = readConfigDict()
        obj["zoom"] = r2(clamped.zoom)
        obj["panX"] = r2(clamped.panX)
        obj["panY"] = r2(clamped.panY)
        let ok = writeConfigDict(obj)
        if !ok {
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_FRAMING persist=fail\n".utf8))
        }
        return ok
    }

    // MARK: - Weather cache (stored under "weatherCache" key)

    static func readWeatherCache() -> WeatherCacheEntry? {
        let obj = readConfigDict()
        guard let wc = obj["weatherCache"] as? [String: Any] else { return nil }
        func d(_ k: String) -> Double? { (wc[k] as? NSNumber)?.doubleValue }
        func n(_ k: String) -> Int?    { (wc[k] as? NSNumber)?.intValue }
        guard let fa = d("fetchedAt"), fa.isFinite,
              let lat = d("lat"), lat.isFinite,
              let lon = d("lon"), lon.isFinite,
              let sr  = d("sunriseEpoch"), sr.isFinite,
              let ss  = d("sunsetEpoch"),  ss.isFinite,
              let wcode = n("weatherCode"),
              let cc = d("cloudCover"), cc.isFinite,
              let pr = d("precipitation"), pr.isFinite else { return nil }
        let ws = (wc["windSpeed"] as? NSNumber)?.doubleValue ?? 0.0
        let wd = (wc["windDirection"] as? NSNumber)?.doubleValue ?? 0.0
        return WeatherCacheEntry(fetchedAt: fa, lat: lat, lon: lon,
                                 sunriseEpoch: sr, sunsetEpoch: ss,
                                 weatherCode: wcode, cloudCover: cc, precipitation: pr,
                                 windSpeed: ws, windDirection: wd)
    }

    @discardableResult
    static func writeWeatherCache(_ entry: WeatherCacheEntry) -> Bool {
        var obj = readConfigDict()
        obj["weatherCache"] = [
            "fetchedAt":      entry.fetchedAt,
            "lat":            entry.lat,
            "lon":            entry.lon,
            "sunriseEpoch":   entry.sunriseEpoch,
            "sunsetEpoch":    entry.sunsetEpoch,
            "weatherCode":    entry.weatherCode,
            "cloudCover":     entry.cloudCover,
            "precipitation":  entry.precipitation,
            "windSpeed":      entry.windSpeed,
            "windDirection":  entry.windDirection
        ] as [String: Any]
        return writeConfigDict(obj)
    }

    // FIX 9: range-check lat/lon to reject out-of-range stored values.
    static func readLatLon() -> (lat: Double, lon: Double)? {
        let obj = readConfigDict()
        guard let lat = (obj["lat"] as? NSNumber)?.doubleValue,
              lat.isFinite, lat >= -90, lat <= 90,
              let lon = (obj["lon"] as? NSNumber)?.doubleValue,
              lon.isFinite, lon >= -180, lon <= 180 else { return nil }
        return (lat, lon)
    }

    @discardableResult
    static func writeLatLon(lat: Double, lon: Double) -> Bool {
        var obj = readConfigDict()
        obj["lat"] = lat
        obj["lon"] = lon
        return writeConfigDict(obj)
    }

    static func appSupportRoot() -> URL {
        if let override = testingRootOverride { return override }
        let env = ProcessInfo.processInfo.environment
        if let override = env["OW_APP_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("OnlyWallpapers", isDirectory: true)
    }

    // FIX 2: SHA256 over concatenated bundle code files as the reseed marker.
    // CFBundleVersion is hardcoded to 1 in package-app.sh so it never changed.
    private static func bundleContentHash(bundleWebDir: URL) throws -> String {
        var hasher = SHA256()
        for name in ["index.html", "style.css", "wallpaper.js"] {
            let data = try Data(contentsOf: bundleWebDir.appendingPathComponent(name))
            hasher.update(data: Data((name + ":").utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func seedWebDirIfNeeded(fromBundleWebDir bundleWebDir: URL) {
        let fm = FileManager.default
        let root = appSupportRoot()
        let webDest = root.appendingPathComponent("web", isDirectory: true)
        let assetsDest = webDest.appendingPathComponent("assets", isDirectory: true)
        let markerFile = webDest.appendingPathComponent(".seed-version")
        let seedTmp = webDest.appendingPathComponent(".seed-tmp", isDirectory: true)

        let isTestMode = ProcessInfo.processInfo.environment["OW_APP_SUPPORT_DIR"] != nil

        do {
            try fm.createDirectory(at: webDest, withIntermediateDirectories: true)
            try fm.createDirectory(at: assetsDest, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_SEED status=fail source=\(bundleWebDir.path) dest=\(webDest.path) reseeded=false error=\(error.localizedDescription)\n".utf8))
            seedFailed = true
            return
        }

        let leftoverPartial = assetsDest.appendingPathComponent("bg.mp4.partial")
        if fm.fileExists(atPath: leftoverPartial.path) {
            try? fm.removeItem(at: leftoverPartial)
        }

        // FIX 2: use content hash rather than CFBundleVersion as the reseed marker.
        let currentHash: String
        do {
            currentHash = try bundleContentHash(bundleWebDir: bundleWebDir)
        } catch {
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_SEED status=fail source=\(bundleWebDir.path) dest=\(webDest.path) reseeded=false error=hash-failed:\(error.localizedDescription)\n".utf8))
            seedFailed = true
            return
        }

        // FIX 3: first-run requires ALL 3 code files present, not just index.html.
        let codeFiles = ["index.html", "style.css", "wallpaper.js"]
        let isFirstRun = !codeFiles.allSatisfy { fm.fileExists(atPath: webDest.appendingPathComponent($0).path) }

        let needsReseed: Bool
        if isFirstRun {
            needsReseed = true
        } else if let storedHash = try? String(contentsOf: markerFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  storedHash == currentHash {
            needsReseed = false
        } else {
            needsReseed = true
        }

        if needsReseed {
            // Atomicity contract: marker-last + reseed-on-mismatch + completeness-reject.
            // Stage all 3 code files to .seed-tmp first, then commit each into web/ with per-file
            // atomic replaceItemAt/moveItem, then write the marker LAST. If interrupted before the
            // marker write, the marker is absent or stale, so the next launch re-seeds. The resolver
            // (WebDirectoryResolver) rejects an incomplete tree (any of the 3 files missing) and
            // falls back to bundle meanwhile. A single atomic 3-file swap is not possible; this
            // triple is the atomicity guarantee.
            if fm.fileExists(atPath: seedTmp.path) {
                try? fm.removeItem(at: seedTmp)
            }
            do {
                try fm.createDirectory(at: seedTmp, withIntermediateDirectories: true)

                // Stage all 3 into .seed-tmp.
                for name in codeFiles {
                    let src = bundleWebDir.appendingPathComponent(name)
                    let dst = seedTmp.appendingPathComponent(name)
                    try fm.copyItem(at: src, to: dst)
                }

                // Verify all 3 staged before touching the live web dir.
                for name in codeFiles {
                    guard fm.fileExists(atPath: seedTmp.appendingPathComponent(name).path) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                }

                // Commit: per-file atomic replace.
                for name in codeFiles {
                    let staged = seedTmp.appendingPathComponent(name)
                    let dest = webDest.appendingPathComponent(name)
                    if fm.fileExists(atPath: dest.path) {
                        _ = try fm.replaceItemAt(dest, withItemAt: staged)
                    } else {
                        try fm.moveItem(at: staged, to: dest)
                    }
                }

                try? fm.removeItem(at: seedTmp)
                try currentHash.write(to: markerFile, atomically: true, encoding: .utf8)
            } catch {
                try? fm.removeItem(at: seedTmp)
                FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_SEED status=fail source=\(bundleWebDir.path) dest=\(webDest.path) reseeded=true error=\(error.localizedDescription)\n".utf8))
                seedFailed = true
                return
            }
        }

        // Seed default asset only when the slot is missing and it is a first run or test mode.
        // FIX 3: log the copy error instead of swallowing it.
        let slotURL = assetsDest.appendingPathComponent("bg.mp4")
        let slotMissing = !fm.fileExists(atPath: slotURL.path)
        if slotMissing && (isFirstRun || isTestMode) {
            let bundleAsset = bundleWebDir.appendingPathComponent("assets").appendingPathComponent("bg.mp4")
            if fm.fileExists(atPath: bundleAsset.path) {
                do {
                    try fm.copyItem(at: bundleAsset, to: slotURL)
                } catch {
                    FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_SEED status=warn source=\(bundleWebDir.path) dest=\(webDest.path) asset-copy-failed=\(error.localizedDescription)\n".utf8))
                }
            }
        }

        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_SEED status=ok source=\(bundleWebDir.path) dest=\(webDest.path) reseeded=\(needsReseed)\n".utf8))
    }
}
