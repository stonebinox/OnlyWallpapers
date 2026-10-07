import Foundation
import CoreGraphics

enum SelfTest {
    static func runAll() {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool) {
            let result = condition ? "pass" : "fail"
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_SELFTEST name=\(name) result=\(result)\n".utf8))
            if condition { passed += 1 } else { failed += 1 }
        }

        // arrangementChanged tests
        let d1 = ScreenDescriptor(displayID: 1, frame: CGRect(x:0, y:0, width:1920, height:1080), scale:2, pixelW:3840, pixelH:2160)
        let d2 = ScreenDescriptor(displayID: 2, frame: CGRect(x:1920, y:0, width:1920, height:1080), scale:2, pixelW:3840, pixelH:2160)
        let d1b = ScreenDescriptor(displayID: 1, frame: CGRect(x:0, y:0, width:1920, height:1080), scale:2, pixelW:3840, pixelH:2160)

        check("arrangementChanged-same", !arrangementChanged(committed: [d1, d2], next: [d2, d1]))
        check("arrangementChanged-diff-frame", arrangementChanged(committed: [d1], next: [ScreenDescriptor(displayID: 1, frame: CGRect(x:0, y:0, width:2560, height:1440), scale:2, pixelW:5120, pixelH:2880)]))
        check("arrangementChanged-diff-count", arrangementChanged(committed: [d1], next: [d1, d2]))
        check("arrangementChanged-empty-empty", !arrangementChanged(committed: [], next: []))
        check("arrangementChanged-copy", !arrangementChanged(committed: [d1], next: [d1b]))

        // computeLayout tests
        let (union1, slices1) = computeLayout([CGRect(x:0, y:0, width:1920, height:1080)])
        check("computeLayout-single-union-w", abs(union1.width - 1920) < 0.5)
        check("computeLayout-single-union-h", abs(union1.height - 1080) < 0.5)
        check("computeLayout-single-offX", abs(slices1[0].offX) < 0.5)
        check("computeLayout-single-offY", abs(slices1[0].offY) < 0.5)

        // T-shape: two 3840x2160 side by side above a 1920x1080 centered at x=1920
        let left4k  = CGRect(x:0,    y:1080, width:3840, height:2160)
        let right4k = CGRect(x:3840, y:1080, width:3840, height:2160)
        let bot1080 = CGRect(x:1920, y:0,    width:1920, height:1080)
        let (tUnion, tSlices) = computeLayout([left4k, right4k, bot1080])
        check("computeLayout-tshape-union-w", abs(tUnion.width - 7680) < 0.5)
        check("computeLayout-tshape-union-h", abs(tUnion.height - 3240) < 0.5)
        check("computeLayout-tshape-left-offX", abs(tSlices[0].offX) < 0.5)
        check("computeLayout-tshape-left-offY", abs(tSlices[0].offY) < 0.5)
        check("computeLayout-tshape-right-offX", abs(tSlices[1].offX - 3840) < 0.5)
        check("computeLayout-tshape-bottom-offX", abs(tSlices[2].offX - 1920) < 0.5)
        check("computeLayout-tshape-bottom-offY", abs(tSlices[2].offY - 2160) < 0.5)

        // Reducer tests
        var r = WallpaperRefreshReducer()
        let committed: [ScreenDescriptor] = [d1]

        // idle + non-empty same = noop
        let a1 = r.snapshot([d1], committed: committed)
        check("reducer-idle-same-noop", a1 == .none)
        check("reducer-idle-same-state", r.pendingState == .idle)

        // idle + non-empty different = scheduleDebounce
        var r2 = WallpaperRefreshReducer()
        let a2 = r2.snapshot([d2], committed: committed)
        check("reducer-idle-diff-debounce", a2 == .scheduleDebounce)
        if case .debouncePending(let n) = r2.pendingState {
            check("reducer-idle-diff-state", n == [d2])
        } else {
            check("reducer-idle-diff-state", false)
        }

        // idle + empty = scheduleEmptyConfirm
        var r3 = WallpaperRefreshReducer()
        let a3 = r3.snapshot([], committed: committed)
        check("reducer-idle-empty-confirm", a3 == .scheduleEmptyConfirm)
        check("reducer-idle-empty-state", r3.pendingState == .emptyConfirmPending)

        // emptyConfirmPending + non-empty equal to committed = cancel pending, .none, .idle
        let a4 = r3.snapshot([d1], committed: committed)
        check("reducer-emptyconfirm-nonempty-noop", a4 == .none)
        check("reducer-emptyconfirm-nonempty-idle", r3.pendingState == .idle)

        // emptyConfirmPending + empty = re-arm
        var r4 = WallpaperRefreshReducer()
        _ = r4.snapshot([], committed: committed)
        let a5 = r4.snapshot([], committed: committed)
        check("reducer-emptyconfirm-empty-rearm", a5 == .scheduleEmptyConfirm)
        check("reducer-emptyconfirm-empty-state", r4.pendingState == .emptyConfirmPending)

        // emptyConfirmFired with valid gen = commitEmpty
        var r5 = WallpaperRefreshReducer()
        _ = r5.snapshot([], committed: committed)
        let a6 = r5.emptyConfirmFired(capturedGen: 3, currentGen: 3)
        check("reducer-emptyconfirmfired-valid", a6 == .commitEmpty)

        // emptyConfirmFired with stale gen = dropStale
        var r6 = WallpaperRefreshReducer()
        _ = r6.snapshot([], committed: committed)
        let a7 = r6.emptyConfirmFired(capturedGen: 1, currentGen: 2)
        check("reducer-emptyconfirmfired-stale", a7 == .dropStale)

        // debounceFired with valid gen = commit
        var r7 = WallpaperRefreshReducer()
        _ = r7.snapshot([d2], committed: committed)
        let a8 = r7.debounceFired(capturedGen: 5, currentGen: 5)
        check("reducer-debouncefired-valid", a8 == .commit([d2]))

        // debounceFired with stale gen = dropStale
        var r8 = WallpaperRefreshReducer()
        _ = r8.snapshot([d2], committed: committed)
        let a9 = r8.debounceFired(capturedGen: 1, currentGen: 2)
        check("reducer-debouncefired-stale", a9 == .dropStale)

        // debouncePending + new snapshot coalesces (still returns scheduleDebounce)
        var r9 = WallpaperRefreshReducer()
        _ = r9.snapshot([d2], committed: committed)
        let d3 = ScreenDescriptor(displayID: 3, frame: CGRect(x:0, y:0, width:2560, height:1440), scale:2, pixelW:5120, pixelH:2880)
        let a10 = r9.snapshot([d3], committed: committed)
        check("reducer-debounce-coalesce", a10 == .scheduleDebounce)
        if case .debouncePending(let n) = r9.pendingState {
            check("reducer-debounce-latest-wins", n == [d3])
        } else {
            check("reducer-debounce-latest-wins", false)
        }

        // empty then non-empty: emptyConfirm should NEVER fire (commitEmpty must not happen)
        var r10 = WallpaperRefreshReducer()
        _ = r10.snapshot([], committed: committed)
        _ = r10.snapshot([d1], committed: committed)
        let a11 = r10.emptyConfirmFired(capturedGen: 99, currentGen: 99)
        check("reducer-empty-then-nonempty-no-commitEmpty", a11 == .dropStale)

        // debouncePending + committed-equal non-empty = cancel pending, .none, .idle (no-op-during-pending)
        var r11 = WallpaperRefreshReducer()
        _ = r11.snapshot([d2], committed: committed)  // enters debouncePending with next=[d2]
        let a12 = r11.snapshot([d1], committed: committed)  // d1 == committed: should no-op
        check("reducer-debounce-noop-during-pending-action", a12 == .none)
        check("reducer-debounce-noop-during-pending-idle", r11.pendingState == .idle)

        // Sentinel IDs: two screens with missing NSScreenNumber get distinct IDs with the high bit set.
        // Real CGDirectDisplayIDs are small positive integers and do not use the high bit (0x80000000).
        let sentinel0: CGDirectDisplayID = 0x8000_0000 | CGDirectDisplayID(0)
        let sentinel1: CGDirectDisplayID = 0x8000_0000 | CGDirectDisplayID(1)
        check("sentinel-high-bit-set", (sentinel0 & 0x8000_0000) != 0)
        check("sentinel-distinct", sentinel0 != sentinel1)
        let ds0 = ScreenDescriptor(displayID: sentinel0, frame: CGRect(x:0, y:0, width:1920, height:1080), scale:2, pixelW:3840, pixelH:2160)
        let ds1 = ScreenDescriptor(displayID: sentinel1, frame: CGRect(x:1920, y:0, width:1920, height:1080), scale:2, pixelW:3840, pixelH:2160)
        check("sentinel-arrangement-changed", arrangementChanged(committed: [ds0], next: [ds1]))

        // MARK: - Mood mapper tests (frozen UTC epochs, TZ-independent)
        let sunrise: Double = 1728367200
        let sunset:  Double = 1728410400
        let noon:    Double = 1728388800   // midday, t=0.5
        let dawn:    Double = 1728367200   // t=0.0
        let dusk:    Double = 1728410400   // t=1.0
        let night:   Double = 1728435600   // t>1, night branch
        let eps = 0.002

        // cssFilter: exact string for neutral
        let neutralFilter = cssFilter(MoodParams.neutral)
        let expectedNeutralFilter = "brightness(1.0100) saturate(1.0000) contrast(1.0100) hue-rotate(0.0000deg) sepia(0.0000)"
        check("mood-cssFilter-exact", neutralFilter == expectedNeutralFilter)

        // Noon: B=1.05, S=1.10, C=1.05, H=0, Se=0.0
        let noonParams = moodParams(nowEpoch: noon, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: nil)
        check("mood-noon-B", abs(noonParams.brightness - 1.05) < eps)
        check("mood-noon-S", abs(noonParams.saturate - 1.10) < eps)
        check("mood-noon-C", abs(noonParams.contrast - 1.05) < eps)
        check("mood-noon-H", noonParams.hueRotate == 0)
        check("mood-noon-Se", abs(noonParams.sepia) < eps)
        check("mood-noon-contrast-floor", noonParams.contrast >= 1.01)

        // Dawn: B=0.92, S=0.90, C=1.05, H=0, Se=0.08
        let dawnParams = moodParams(nowEpoch: dawn, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: nil)
        check("mood-dawn-B", abs(dawnParams.brightness - 0.92) < eps)
        check("mood-dawn-S", abs(dawnParams.saturate - 0.90) < eps)
        check("mood-dawn-Se", abs(dawnParams.sepia - 0.08) < eps)
        check("mood-dawn-contrast-floor", dawnParams.contrast >= 1.01)

        // Dusk: same as dawn (t=1.0, cos(pi)=-1, cos^2=1)
        let duskParams = moodParams(nowEpoch: dusk, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: nil)
        check("mood-dusk-B", abs(duskParams.brightness - 0.92) < eps)
        check("mood-dusk-Se", abs(duskParams.sepia - 0.08) < eps)
        check("mood-dusk-contrast-floor", duskParams.contrast >= 1.01)

        // Night: B=0.92, S=0.80, Se=0.0
        let nightParams = moodParams(nowEpoch: night, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: nil)
        check("mood-night-B", abs(nightParams.brightness - 0.92) < eps)
        check("mood-night-S", abs(nightParams.saturate - 0.80) < eps)
        check("mood-night-Se", abs(nightParams.sepia) < eps)
        check("mood-night-contrast-floor", nightParams.contrast >= 1.01)

        // Nil-weather time-varying: dawn != noon != night (brightness varies)
        check("mood-time-varying-dawn-ne-noon", abs(dawnParams.brightness - noonParams.brightness) > 0.05)
        check("mood-time-varying-night-ne-noon", abs(nightParams.saturate - noonParams.saturate) > 0.05)
        check("mood-time-varying-dawn-ne-night-sepia", abs(dawnParams.sepia - nightParams.sepia) > 0.05)

        // Clear weather (code=0, cloud=0, precip=0): same as nil at noon
        let clearW = WeatherInput(weatherCode: 0, cloudCover: 0, precipitation: 0)
        let clearParams = moodParams(nowEpoch: noon, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: clearW)
        check("mood-clear-B", abs(clearParams.brightness - 1.05) < eps)
        check("mood-clear-contrast-floor", clearParams.contrast >= 1.01)

        // Cloudy (code=3, cloud=80, precip=0) at noon: B and S muted vs clear
        let cloudW = WeatherInput(weatherCode: 3, cloudCover: 80, precipitation: 0)
        let cloudParams = moodParams(nowEpoch: noon, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: cloudW)
        check("mood-cloudy-B-muted", cloudParams.brightness < clearParams.brightness)
        check("mood-cloudy-S-muted", cloudParams.saturate < clearParams.saturate)
        check("mood-cloudy-contrast-floor", cloudParams.contrast >= 1.01)

        // Storm (code=95, cloud=100, precip=10) at noon: measurably more muted than clear
        let stormW = WeatherInput(weatherCode: 95, cloudCover: 100, precipitation: 10)
        let stormParams = moodParams(nowEpoch: noon, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: stormW)
        check("mood-storm-dimmer-than-clear", stormParams.brightness < clearParams.brightness)
        check("mood-storm-more-desaturated-than-clear", stormParams.saturate < clearParams.saturate)
        check("mood-storm-dimmer-than-cloudy", stormParams.brightness <= cloudParams.brightness)
        check("mood-storm-contrast-floor", stormParams.contrast >= 1.01)
        check("mood-storm-B-clamp", stormParams.brightness >= 0.85)

        // Snow (code=71, cloud=0, precip=0) at noon: brighter than clear (B+=0.05), clamped to 1.08
        let snowW = WeatherInput(weatherCode: 71, cloudCover: 0, precipitation: 0)
        let snowParams = moodParams(nowEpoch: noon, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: snowW)
        check("mood-snow-brighter-or-eq", snowParams.brightness >= clearParams.brightness)
        check("mood-snow-B-clamp", snowParams.brightness <= 1.08)
        check("mood-snow-contrast-floor", snowParams.contrast >= 1.01)

        // Polar guard: sunset <= sunrise -> returns clamped profile, no divide
        let polarParams = moodParams(nowEpoch: noon, sunriseEpoch: 1000, sunsetEpoch: 500, weather: nil)
        check("mood-polar-B-in-range", polarParams.brightness >= 0.85 && polarParams.brightness <= 1.08)
        check("mood-polar-contrast-floor", polarParams.contrast >= 1.01)
        check("mood-polar-H-pinned", polarParams.hueRotate == 0)

        // Clamps: storm + night cannot go below floor
        let stormNight = moodParams(nowEpoch: night, sunriseEpoch: sunrise, sunsetEpoch: sunset,
                                    weather: WeatherInput(weatherCode: 99, cloudCover: 100, precipitation: 30))
        check("mood-clamp-B-lower", stormNight.brightness >= 0.85)
        check("mood-clamp-S-lower", stormNight.saturate >= 0.70)
        check("mood-clamp-C-floor", stormNight.contrast >= 1.01)
        check("mood-clamp-Se-upper", stormNight.sepia <= 0.12)

        // Precipitation test (FIX 8): mild WMO code but heavy precipitation mutes more than no precipitation
        let mildNoPrecip = WeatherInput(weatherCode: 1, cloudCover: 20, precipitation: 0)
        let mildHeavyPrecip = WeatherInput(weatherCode: 1, cloudCover: 20, precipitation: 40)
        let mildNoPrecipParams = moodParams(nowEpoch: noon, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: mildNoPrecip)
        let mildHeavyPrecipParams = moodParams(nowEpoch: noon, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: mildHeavyPrecip)
        check("mood-precip-desaturates", mildHeavyPrecipParams.saturate < mildNoPrecipParams.saturate)
        check("mood-precip-dims", mildHeavyPrecipParams.brightness < mildNoPrecipParams.brightness)

        // cssFilter: exact string verification for non-neutral
        let noonFilter = cssFilter(noonParams)
        check("mood-cssFilter-noon-brightness", noonFilter.hasPrefix("brightness(1.0500)"))
        check("mood-cssFilter-noon-order", noonFilter.contains("brightness(") && noonFilter.contains(" saturate(") && noonFilter.contains(" contrast(") && noonFilter.contains(" hue-rotate(") && noonFilter.contains(" sepia("))
        let noonFilterParts = noonFilter.components(separatedBy: " ")
        check("mood-cssFilter-5-parts", noonFilterParts.count == 5)

        // MARK: - WeatherHysteresis fetch-driven tests
        var hyst = WeatherHysteresis()
        // appliedGroup starts .clear; first resolve with clear code: agree, returns incoming
        let hr1 = hyst.resolve(incomingCode: 0)
        check("hysteresis-agree-returns-incoming", hr1 == 0)
        check("hysteresis-agree-group-clear", hyst.appliedGroup == .clear)
        check("hysteresis-agree-disagrees-reset", hyst.consecutiveDisagrees == 0)

        // First disagreeing fetch (storm): sticky, still returns clear representative
        let hr2 = hyst.resolve(incomingCode: 95)
        check("hysteresis-1fetch-disagree-sticky", hr2 == 0)
        check("hysteresis-1fetch-group-unchanged", hyst.appliedGroup == .clear)
        check("hysteresis-1fetch-disagrees-count", hyst.consecutiveDisagrees == 1)

        // Second disagreeing fetch (storm): switches group
        let hr3 = hyst.resolve(incomingCode: 95)
        check("hysteresis-2fetch-disagree-switches", hr3 == 95)
        check("hysteresis-2fetch-group-storm", hyst.appliedGroup == .storm)
        check("hysteresis-2fetch-disagrees-reset", hyst.consecutiveDisagrees == 0)

        // Agree after switch: returns incoming storm code
        let hr4 = hyst.resolve(incomingCode: 99)
        check("hysteresis-post-switch-agree", hr4 == 99)
        check("hysteresis-post-switch-group-storm", hyst.appliedGroup == .storm)

        // Intermittent: one disagree then agree resets count, preventing switch
        var hyst2 = WeatherHysteresis()
        _ = hyst2.resolve(incomingCode: 0)   // clear applied
        _ = hyst2.resolve(incomingCode: 95)  // 1 disagree
        _ = hyst2.resolve(incomingCode: 0)   // back to clear: agree, resets count
        let hr5 = hyst2.resolve(incomingCode: 95) // 1 disagree again (count was reset to 0)
        check("hysteresis-intermittent-still-sticky", hr5 == 0) // still returns clear representative
        check("hysteresis-intermittent-group-still-clear", hyst2.appliedGroup == .clear)

        // First-fetch nil-seed tests: storm on first fetch applies immediately.
        var hyst3 = WeatherHysteresis()
        let hfr1 = hyst3.resolve(incomingCode: 95)  // first fetch: nil -> storm immediately
        check("hysteresis-nil-seed-first-fetch-storm", hfr1 == 95)
        check("hysteresis-nil-seed-applied-storm", hyst3.appliedGroup == .storm)
        check("hysteresis-nil-seed-disagrees-zero", hyst3.consecutiveDisagrees == 0)

        // Single clear after storm: must NOT revert (needs 2 consecutive).
        let hfr2 = hyst3.resolve(incomingCode: 0)
        check("hysteresis-nil-seed-single-clear-sticky", hfr2 == 95)  // returns storm representative
        check("hysteresis-nil-seed-single-clear-group-unchanged", hyst3.appliedGroup == .storm)
        check("hysteresis-nil-seed-single-clear-disagrees", hyst3.consecutiveDisagrees == 1)

        // Second clear: reverts to clear.
        let hfr3 = hyst3.resolve(incomingCode: 0)
        check("hysteresis-nil-seed-two-clears-reverts", hfr3 == 0)
        check("hysteresis-nil-seed-two-clears-group-clear", hyst3.appliedGroup == .clear)
        check("hysteresis-nil-seed-two-clears-disagrees-reset", hyst3.consecutiveDisagrees == 0)

        // MARK: - Exact-tuple selftests per weather group (Issue 6)
        // Isolated: cloud=0, precip=0, noon epoch, fixed sun times.
        let grpSunrise: Double = 1728367200
        let grpSunset: Double  = 1728410400
        let grpNoon: Double    = 1728388800
        let grpEps = 0.0005

        let clearG = moodParams(nowEpoch: grpNoon, sunriseEpoch: grpSunrise, sunsetEpoch: grpSunset,
                                 weather: WeatherInput(weatherCode: 0, cloudCover: 0, precipitation: 0))
        check("exact-clear-B",  abs(clearG.brightness - 1.0500) < grpEps)
        check("exact-clear-S",  abs(clearG.saturate   - 1.1000) < grpEps)
        check("exact-clear-C",  abs(clearG.contrast   - 1.0500) < grpEps)
        check("exact-clear-Se", abs(clearG.sepia)               < grpEps)

        let cloudyG = moodParams(nowEpoch: grpNoon, sunriseEpoch: grpSunrise, sunsetEpoch: grpSunset,
                                  weather: WeatherInput(weatherCode: 3, cloudCover: 0, precipitation: 0))
        check("exact-cloudy-B",  abs(cloudyG.brightness - 1.0500) < grpEps)
        check("exact-cloudy-S",  abs(cloudyG.saturate   - 1.1000) < grpEps)
        check("exact-cloudy-C",  abs(cloudyG.contrast   - 1.0500) < grpEps)
        check("exact-cloudy-Se", abs(cloudyG.sepia)                < grpEps)

        let fogG = moodParams(nowEpoch: grpNoon, sunriseEpoch: grpSunrise, sunsetEpoch: grpSunset,
                               weather: WeatherInput(weatherCode: 45, cloudCover: 0, precipitation: 0))
        check("exact-fog-B",  abs(fogG.brightness - 1.0500) < grpEps)
        check("exact-fog-S",  abs(fogG.saturate   - 1.1000) < grpEps)
        check("exact-fog-C",  abs(fogG.contrast   - 1.0100) < grpEps)  // 1.05-0.05=1.00 -> floor 1.01
        check("exact-fog-Se", abs(fogG.sepia)                < grpEps)

        let rainG = moodParams(nowEpoch: grpNoon, sunriseEpoch: grpSunrise, sunsetEpoch: grpSunset,
                                weather: WeatherInput(weatherCode: 61, cloudCover: 0, precipitation: 0))
        check("exact-rain-B",  abs(rainG.brightness - 1.0100) < grpEps)  // 1.05-0.04=1.01
        check("exact-rain-S",  abs(rainG.saturate   - 1.0200) < grpEps)  // 1.10-0.08=1.02
        check("exact-rain-C",  abs(rainG.contrast   - 1.0500) < grpEps)
        check("exact-rain-Se", abs(rainG.sepia)                < grpEps)

        let stormG = moodParams(nowEpoch: grpNoon, sunriseEpoch: grpSunrise, sunsetEpoch: grpSunset,
                                 weather: WeatherInput(weatherCode: 95, cloudCover: 0, precipitation: 0))
        check("exact-storm-B",  abs(stormG.brightness - 0.9700) < grpEps)  // 1.05-0.08=0.97
        check("exact-storm-S",  abs(stormG.saturate   - 0.9500) < grpEps)  // 1.10-0.15=0.95
        check("exact-storm-C",  abs(stormG.contrast   - 1.0500) < grpEps)
        check("exact-storm-Se", abs(stormG.sepia)                < grpEps)

        let snowG = moodParams(nowEpoch: grpNoon, sunriseEpoch: grpSunrise, sunsetEpoch: grpSunset,
                                weather: WeatherInput(weatherCode: 71, cloudCover: 0, precipitation: 0))
        check("exact-snow-B",  abs(snowG.brightness - 1.0800) < grpEps)  // 1.05+0.05=1.10->clamp 1.08
        check("exact-snow-S",  abs(snowG.saturate   - 1.0500) < grpEps)  // 1.10-0.05=1.05
        check("exact-snow-C",  abs(snowG.contrast   - 1.0500) < grpEps)
        check("exact-snow-Se", abs(snowG.sepia)                < grpEps)

        // MARK: - Config merge regression tests
        // Create temp dir, override appSupportRoot, run tests, restore.
        let cmTmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-merge-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: cmTmpDir, withIntermediateDirectories: true)
        AppStorageManager.testingRootOverride = cmTmpDir
        let cfgURL = cmTmpDir.appendingPathComponent("config.json")

        // Seed config with lat, lon, weatherCache
        let seedObj: [String: Any] = [
            "lat": 37.77,
            "lon": -122.42,
            "weatherCache": [
                "fetchedAt": 1728388800.0, "lat": 37.77, "lon": -122.42,
                "sunriseEpoch": 1728367200.0, "sunsetEpoch": 1728410400.0,
                "weatherCode": 0, "cloudCover": 0.0, "precipitation": 0.0
            ] as [String: Any]
        ]
        if let seedData = try? JSONSerialization.data(withJSONObject: seedObj) {
            try? seedData.write(to: cfgURL)
        }

        // writeFraming must write zoom/panX/panY AND preserve lat, lon, weatherCache
        let wfOk = AppStorageManager.writeFraming(AppStorageManager.FramingConfig(zoom: 1.5, panX: 0.25, panY: -0.3))
        check("config-merge-writeFraming-returns-ok", wfOk)
        let afterFraming = (try? JSONSerialization.jsonObject(with: Data(contentsOf: cfgURL))) as? [String: Any] ?? [:]
        check("config-merge-writeFraming-zoom", abs(((afterFraming["zoom"] as? NSNumber)?.doubleValue ?? 0) - 1.5) < 0.01)
        check("config-merge-writeFraming-panX", abs(((afterFraming["panX"] as? NSNumber)?.doubleValue ?? 0) - 0.25) < 0.01)
        check("config-merge-writeFraming-panY", abs(((afterFraming["panY"] as? NSNumber)?.doubleValue ?? 0) - (-0.3)) < 0.01)
        check("config-merge-writeFraming-lat-preserved", abs(((afterFraming["lat"] as? NSNumber)?.doubleValue ?? 999) - 37.77) < 0.001)
        check("config-merge-writeFraming-lon-preserved", abs(((afterFraming["lon"] as? NSNumber)?.doubleValue ?? 999) - (-122.42)) < 0.001)
        check("config-merge-writeFraming-weatherCache-preserved", afterFraming["weatherCache"] != nil)

        // Seed config with only zoom/panX/panY (no lat/lon)
        let framedSeed: [String: Any] = ["zoom": 1.3, "panX": 0.1, "panY": 0.2]
        if let fd = try? JSONSerialization.data(withJSONObject: framedSeed) { try? fd.write(to: cfgURL) }

        // writeWeatherCache must write cache AND preserve zoom/panX/panY
        let wcEntry = WeatherCacheEntry(fetchedAt: 1728388800, lat: 37.77, lon: -122.42,
                                         sunriseEpoch: 1728367200, sunsetEpoch: 1728410400,
                                         weatherCode: 61, cloudCover: 50.0, precipitation: 2.0)
        let wcOk = AppStorageManager.writeWeatherCache(wcEntry)
        check("config-merge-writeWeatherCache-returns-ok", wcOk)
        let afterWC = (try? JSONSerialization.jsonObject(with: Data(contentsOf: cfgURL))) as? [String: Any] ?? [:]
        check("config-merge-writeWeatherCache-zoom-preserved", abs(((afterWC["zoom"] as? NSNumber)?.doubleValue ?? 0) - 1.3) < 0.01)
        check("config-merge-writeWeatherCache-panX-preserved", abs(((afterWC["panX"] as? NSNumber)?.doubleValue ?? 999) - 0.1) < 0.01)
        check("config-merge-writeWeatherCache-weatherCache-written", afterWC["weatherCache"] != nil)

        // Seed config with zoom only
        let zoomSeed: [String: Any] = ["zoom": 1.6, "panX": 0.0, "panY": 0.5]
        if let zd = try? JSONSerialization.data(withJSONObject: zoomSeed) { try? zd.write(to: cfgURL) }

        // writeLatLon must write lat/lon AND preserve zoom/panX/panY
        let llOk = AppStorageManager.writeLatLon(lat: 51.5, lon: -0.1)
        check("config-merge-writeLatLon-returns-ok", llOk)
        let afterLL = (try? JSONSerialization.jsonObject(with: Data(contentsOf: cfgURL))) as? [String: Any] ?? [:]
        check("config-merge-writeLatLon-lat-written", abs(((afterLL["lat"] as? NSNumber)?.doubleValue ?? 999) - 51.5) < 0.001)
        check("config-merge-writeLatLon-lon-written", abs(((afterLL["lon"] as? NSNumber)?.doubleValue ?? 999) - (-0.1)) < 0.001)
        check("config-merge-writeLatLon-zoom-preserved", abs(((afterLL["zoom"] as? NSNumber)?.doubleValue ?? 0) - 1.6) < 0.01)
        check("config-merge-writeLatLon-panY-preserved", abs(((afterLL["panY"] as? NSNumber)?.doubleValue ?? 999) - 0.5) < 0.01)

        // MARK: - openMeteoURL pure function tests
        let testLat = (37.7749 * 100).rounded() / 100  // 37.77
        let testLon = (-122.4194 * 100).rounded() / 100 // -122.42
        let urlStr = MoodController.openMeteoURL(lat: testLat, lon: testLon)
        let urlObj = URL(string: urlStr)!
        check("openMeteoURL-host", urlObj.host == "api.open-meteo.com")
        check("openMeteoURL-path", urlObj.path == "/v1/forecast")
        let query = urlObj.query ?? ""
        check("openMeteoURL-lat-2dp", query.contains("latitude=37.77"))
        check("openMeteoURL-lon-2dp", query.contains("longitude=-122.42"))
        check("openMeteoURL-timeformat", query.contains("timeformat=unixtime"))
        check("openMeteoURL-timezone", query.contains("timezone=auto"))
        check("openMeteoURL-current-fields", query.contains("weather_code") && query.contains("cloud_cover") && query.contains("precipitation") && query.contains("is_day"))
        check("openMeteoURL-daily-fields", query.contains("daily=sunrise,sunset") || (query.contains("daily=") && query.contains("sunrise") && query.contains("sunset")))

        // MARK: - Weather cache round-trip selftest
        // The cmTmpDir and testingRootOverride are already set from the config-merge block above.
        // Re-seed config.json with a zoom key so we can verify it survives the cache write.
        let wcRtPreSeed: [String: Any] = ["zoom": 1.4, "panX": 0.1, "panY": -0.1]
        if let d = try? JSONSerialization.data(withJSONObject: wcRtPreSeed) { try? d.write(to: cfgURL) }

        let rtEntry = WeatherCacheEntry(
            fetchedAt: 1728388800.0,
            lat: 37.77, lon: -122.42,
            sunriseEpoch: 1728367200.0, sunsetEpoch: 1728410400.0,
            weatherCode: 61, cloudCover: 75.0, precipitation: 2.5
        )
        let rtWriteOk = AppStorageManager.writeWeatherCache(rtEntry)
        check("cache-rt-write-ok", rtWriteOk)

        let rtRead = AppStorageManager.readWeatherCache()
        check("cache-rt-read-non-nil", rtRead != nil)
        if let rt = rtRead {
            check("cache-rt-fetchedAt",    abs(rt.fetchedAt    - rtEntry.fetchedAt)    < 0.01)
            check("cache-rt-lat",          abs(rt.lat          - rtEntry.lat)          < 0.001)
            check("cache-rt-lon",          abs(rt.lon          - rtEntry.lon)          < 0.001)
            check("cache-rt-sunriseEpoch", abs(rt.sunriseEpoch - rtEntry.sunriseEpoch) < 0.01)
            check("cache-rt-sunsetEpoch",  abs(rt.sunsetEpoch  - rtEntry.sunsetEpoch)  < 0.01)
            check("cache-rt-weatherCode",  rt.weatherCode == rtEntry.weatherCode)
            check("cache-rt-cloudCover",   abs(rt.cloudCover   - rtEntry.cloudCover)   < 0.01)
            check("cache-rt-precipitation",abs(rt.precipitation - rtEntry.precipitation) < 0.001)
        }
        // Verify pre-seeded zoom key survived (merge must not clobber other keys)
        let rtAfterDict = (try? JSONSerialization.jsonObject(with: Data(contentsOf: cfgURL))) as? [String: Any] ?? [:]
        check("cache-rt-zoom-survived", abs(((rtAfterDict["zoom"] as? NSNumber)?.doubleValue ?? 0) - 1.4) < 0.01)

        // MARK: - shouldFetch backoff tests
        let epoch0: Double = 1_700_000_000
        // Never attempted: always true
        check("shouldFetch-never-attempted",
              MoodController.shouldFetch(now: epoch0, lastAttempt: 0, lastAttemptLatLon: nil,
                                         currentLatLon: (37.77, -122.42)))

        // Within 900s, same location: false
        check("shouldFetch-within-900s-same-loc",
              !MoodController.shouldFetch(now: epoch0 + 300, lastAttempt: epoch0,
                                          lastAttemptLatLon: (37.77, -122.42),
                                          currentLatLon: (37.77, -122.42)))

        // After 900s, same location: true
        check("shouldFetch-after-900s",
              MoodController.shouldFetch(now: epoch0 + 900, lastAttempt: epoch0,
                                         lastAttemptLatLon: (37.77, -122.42),
                                         currentLatLon: (37.77, -122.42)))

        // Within 900s, moved >0.15 deg: true (genuine move)
        check("shouldFetch-within-900s-moved-far",
              MoodController.shouldFetch(now: epoch0 + 300, lastAttempt: epoch0,
                                         lastAttemptLatLon: (37.77, -122.42),
                                         currentLatLon: (38.00, -122.42)))

        // Within 900s, moved <0.15 deg: false
        check("shouldFetch-within-900s-moved-small",
              !MoodController.shouldFetch(now: epoch0 + 300, lastAttempt: epoch0,
                                          lastAttemptLatLon: (37.77, -122.42),
                                          currentLatLon: (37.80, -122.42)))

        // MARK: - shouldFetch: seeded from persisted cache (Fix 1)
        // These mirror the init() seeding: lastFetchedAt = cache.fetchedAt, lastAttemptLatLon = (cache.lat, cache.lon)
        let cacheSeededAt: Double = 1_700_000_100
        let cacheSeededLat: Double = 37.77
        let cacheSeededLon: Double = -122.42
        // Fresh cache (age 300s < 900s), same location: must NOT refetch
        check("shouldFetch-seeded-from-cache-fresh",
              !MoodController.shouldFetch(now: cacheSeededAt + 300,
                                          lastAttempt: cacheSeededAt,
                                          lastAttemptLatLon: (cacheSeededLat, cacheSeededLon),
                                          currentLatLon: (cacheSeededLat, cacheSeededLon)))
        // Stale cache (age 900s), same location: must refetch
        check("shouldFetch-seeded-from-cache-stale",
              MoodController.shouldFetch(now: cacheSeededAt + 900,
                                         lastAttempt: cacheSeededAt,
                                         lastAttemptLatLon: (cacheSeededLat, cacheSeededLon),
                                         currentLatLon: (cacheSeededLat, cacheSeededLon)))

        // OPT-IN path: forced=true fetches even with a fresh same-location cache
        check("shouldFetch-optin-forced-fresh",
              MoodController.shouldFetchOrForced(
                  forced: true,
                  now: cacheSeededAt + 300,
                  lastAttempt: cacheSeededAt,
                  lastAttemptLatLon: (cacheSeededLat, cacheSeededLon),
                  currentLatLon: (cacheSeededLat, cacheSeededLon)))
        // TIMER path: forced=false keeps the throttle
        check("shouldFetch-timer-throttle-fresh",
              !MoodController.shouldFetchOrForced(
                  forced: false,
                  now: cacheSeededAt + 300,
                  lastAttempt: cacheSeededAt,
                  lastAttemptLatLon: (cacheSeededLat, cacheSeededLon),
                  currentLatLon: (cacheSeededLat, cacheSeededLon)))

        // MARK: - Stale sun epoch / fresh weather decoupling (Fix 2)
        // 25h after yesterday's sunrise puts 'now' past the 24h cache window; the time
        // curve must use synthesized 06:00/18:00 while cached weather still modulates.
        let ystrSr: Double = 1728367200  // yesterday's sunrise
        let ystrSs: Double = 1728410400  // yesterday's sunset (12h span)
        let nowIn25h: Double = ystrSr + 25 * 3600  // past the 24h window

        // Confirm stale sun produces t > 1 (night branch) regardless of actual time-of-day
        let tStale = (nowIn25h - ystrSr) / (ystrSs - ystrSr)  // 90000/43200 = 2.083
        check("stale-sun-t-gt-1", tStale > 1.0)
        let staleTimeParams = moodParams(nowEpoch: nowIn25h, sunriseEpoch: ystrSr, sunsetEpoch: ystrSs, weather: nil)
        check("stale-sun-gives-night-S", abs(staleTimeParams.saturate - 0.80) < 0.002)

        // Synthesized sun for nowIn25h: 06:00/18:00 span is exactly 12h
        let synNow = MoodController.synthesizeSunTimes(referenceEpoch: nowIn25h)
        check("synSun-span-12h", abs((synNow.sunset - synNow.sunrise) - 12 * 3600) < 1.0)

        // Cached storm weather still modulates even when sun is synthesized
        let stormWx = WeatherInput(weatherCode: 95, cloudCover: 100, precipitation: 5.0)
        let synNoWx   = moodParams(nowEpoch: nowIn25h, sunriseEpoch: synNow.sunrise, sunsetEpoch: synNow.sunset, weather: nil)
        let synStorm  = moodParams(nowEpoch: nowIn25h, sunriseEpoch: synNow.sunrise, sunsetEpoch: synNow.sunset, weather: stormWx)
        check("stale-sun-weather-dims", synStorm.brightness < synNoWx.brightness)
        check("stale-sun-weather-desats", synStorm.saturate < synNoWx.saturate)

        // MARK: - parseOpenMeteoResponse parser tests
        // Canonical Open-Meteo unixtime response (epoch seconds for sunrise/sunset).
        let canonicalJSON = """
{"current":{"weather_code":61,"cloud_cover":75,"precipitation":2.5,"is_day":1,"time":1728388800},"daily":{"sunrise":[1728367200],"sunset":[1728410400]}}
"""
        let canonicalData = canonicalJSON.data(using: .utf8)!
        let parsedEntry = MoodController.parseOpenMeteoResponse(data: canonicalData, lat: 37.77, lon: -122.42)
        check("parseOpenMeteo-returns-non-nil", parsedEntry != nil)
        if let e = parsedEntry {
            check("parseOpenMeteo-lat",           abs(e.lat - 37.77)      < 0.001)
            check("parseOpenMeteo-lon",           abs(e.lon - (-122.42))  < 0.001)
            check("parseOpenMeteo-weatherCode",   e.weatherCode == 61)
            check("parseOpenMeteo-cloudCover",    abs(e.cloudCover - 75.0) < 0.01)
            check("parseOpenMeteo-precipitation", abs(e.precipitation - 2.5) < 0.001)
            check("parseOpenMeteo-sunriseEpoch",  abs(e.sunriseEpoch - 1728367200) < 0.01)
            check("parseOpenMeteo-sunsetEpoch",   abs(e.sunsetEpoch  - 1728410400) < 0.01)
            check("parseOpenMeteo-fetchedAt-positive", e.fetchedAt > 0)
        }

        // Malformed JSON returns nil, does not crash.
        let malformedData = "not-json".data(using: .utf8)!
        check("parseOpenMeteo-malformed-nil",
              MoodController.parseOpenMeteoResponse(data: malformedData, lat: 0, lon: 0) == nil)

        // Missing required field (no weather_code) returns nil.
        let missingFieldJSON = """
{"current":{"cloud_cover":75,"precipitation":2.5},"daily":{"sunrise":[1728367200],"sunset":[1728410400]}}
"""
        let missingData = missingFieldJSON.data(using: .utf8)!
        check("parseOpenMeteo-missing-field-nil",
              MoodController.parseOpenMeteoResponse(data: missingData, lat: 0, lon: 0) == nil)

        // MARK: - readLatLon range regression tests
        let cfgURL2 = cmTmpDir.appendingPathComponent("config.json")

        func writeAndReadLatLon(lat: Any?, lon: Any?) -> (lat: Double, lon: Double)? {
            var obj2: [String: Any] = [:]
            if let l = lat { obj2["lat"] = l }
            if let l = lon { obj2["lon"] = l }
            if let d = try? JSONSerialization.data(withJSONObject: obj2) { try? d.write(to: cfgURL2) }
            return AppStorageManager.readLatLon()
        }

        // In-range: accepted
        check("latlon-inrange-accepted", writeAndReadLatLon(lat: 37.77, lon: -122.42) != nil)

        // Out-of-range: rejected
        check("latlon-lat91-rejected", writeAndReadLatLon(lat: 91.0, lon: 0.0) == nil)
        check("latlon-lat-neg91-rejected", writeAndReadLatLon(lat: -91.0, lon: 0.0) == nil)
        check("latlon-lon181-rejected", writeAndReadLatLon(lat: 0.0, lon: 181.0) == nil)
        check("latlon-lon-neg181-rejected", writeAndReadLatLon(lat: 0.0, lon: -181.0) == nil)

        // Boundary: accepted
        check("latlon-lat90-accepted", writeAndReadLatLon(lat: 90.0, lon: 0.0) != nil)
        check("latlon-lat-neg90-accepted", writeAndReadLatLon(lat: -90.0, lon: 0.0) != nil)
        check("latlon-lon180-accepted", writeAndReadLatLon(lat: 0.0, lon: 180.0) != nil)
        check("latlon-lon-neg180-accepted", writeAndReadLatLon(lat: 0.0, lon: -180.0) != nil)

        // Null value (non-finite equivalent in JSON): rejected
        let nullLatData = Data("{\"lat\":null,\"lon\":0}".utf8)
        try? nullLatData.write(to: cfgURL2)
        check("latlon-null-lat-rejected", AppStorageManager.readLatLon() == nil)

        let nullLonData = Data("{\"lat\":0,\"lon\":null}".utf8)
        try? nullLonData.write(to: cfgURL2)
        check("latlon-null-lon-rejected", AppStorageManager.readLatLon() == nil)

        AppStorageManager.testingRootOverride = nil
        try? FileManager.default.removeItem(at: cmTmpDir)
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_SELFTEST summary passed=\(passed) failed=\(failed)\n".utf8))
        exit(failed == 0 ? 0 : 1)
    }
}
