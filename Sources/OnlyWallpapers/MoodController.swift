import AppKit
import CoreLocation
import Foundation

// Stored in config.json under "weatherCache" key.
struct WeatherCacheEntry {
    let fetchedAt: Double
    let lat: Double
    let lon: Double
    let sunriseEpoch: Double
    let sunsetEpoch: Double
    let weatherCode: Int
    let cloudCover: Double
    let precipitation: Double
}

@MainActor
final class MoodController: NSObject {

    enum Mode { case hook, noPlist, normal }

    private let mode: Mode
    private var locationManager: CLLocationManager?
    private var locationDelegate: _LocationDelegate?
    nonisolated(unsafe) private var moodTimer: Timer?
    nonisolated(unsafe) private var wakeObserver: Any?

    private var lastFetchedAt: Double = 0
    private var lastAttemptLatLon: (lat: Double, lon: Double)?
    private var currentCache: WeatherCacheEntry?
    private var lastLocationLatLon: (lat: Double, lon: Double)?
    private var authorized: Bool = false
    private var forcedFetch: Bool = false

    // Hysteresis: fetch-driven, moves to WeatherHysteresis struct.
    private var hysteresis = WeatherHysteresis()
    private var effectiveWeatherCode: Int? = nil

    var onMoodUpdate: ((MoodParams) -> Void)?

    override init() {
        let env = ProcessInfo.processInfo.environment
        if env["OW_MOOD_TEST"] == "1" {
            mode = .hook
        } else if Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") == nil {
            mode = .noPlist
        } else {
            mode = .normal
        }
        // FIX 1: read cache during init, but do NOT broadcast yet.
        // start() is called by AppDelegate after onMoodUpdate is wired.
        currentCache = AppStorageManager.readWeatherCache()
        super.init()
        if let cache = currentCache {
            hysteresis.appliedGroup = WeatherGroup(code: cache.weatherCode)
            effectiveWeatherCode = cache.weatherCode
            lastFetchedAt = cache.fetchedAt
            lastAttemptLatLon = (cache.lat, cache.lon)
        }
    }

    // FIX 1: Called by AppDelegate after onMoodUpdate is assigned.
    func start() {
        let env = ProcessInfo.processInfo.environment
        switch mode {
        case .hook:
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD mood=hook\n".utf8))
            applyHookMood(env: env)

        case .noPlist:
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD location=no-plist\n".utf8))
            computeAndBroadcast()
            startMoodTimer()
            observeWake()
            if let (lat, lon) = effectiveLatLon() {
                Task { await fetchWeatherIfNeeded(lat: lat, lon: lon) }
            }

        case .normal:
            computeAndBroadcast()
            startMoodTimer()
            observeWake()
            if let (lat, lon) = effectiveLatLon() {
                Task { await fetchWeatherIfNeeded(lat: lat, lon: lon) }
            }
        }
    }

    // Called from StatusItemController when user taps "Use location for weather tint".
    func requestLocationOptIn() {
        guard mode == .normal else { return }
        if locationManager == nil { buildLocationManager() }
        guard let mgr = locationManager else { return }
        switch mgr.authorizationStatus {
        case .notDetermined:
            forcedFetch = true
            mgr.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            authorized = true
            forcedFetch = true
            mgr.requestLocation()
        default:
            break
        }
    }

    private func buildLocationManager() {
        let delegate = _LocationDelegate(
            onLocation: { [weak self] lat, lon in
                Task { @MainActor [weak self] in self?.handleLocation(lat: lat, lon: lon) }
            },
            onFail: { [weak self] err in
                Task { @MainActor [weak self] in self?.handleLocationFail(err) }
            },
            onAuth: { [weak self] status in
                Task { @MainActor [weak self] in self?.handleAuthChange(status) }
            }
        )
        let mgr = CLLocationManager()
        mgr.delegate = delegate
        mgr.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager = mgr
        locationDelegate = delegate
    }

    private func handleLocation(lat: Double, lon: Double) {
        let lat2 = (lat * 100).rounded() / 100
        let lon2 = (lon * 100).rounded() / 100
        lastLocationLatLon = (lat2, lon2)
        _ = AppStorageManager.writeLatLon(lat: lat2, lon: lon2)
        let forced = forcedFetch
        if forced { forcedFetch = false }
        Task { await fetchWeatherIfNeeded(lat: lat2, lon: lon2, forced: forced) }
    }

    private func handleLocationFail(_ error: Error) {
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD location=fail error=\(error.localizedDescription)\n".utf8))
        computeAndBroadcast()
    }

    private func handleAuthChange(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            authorized = true
            locationManager?.requestLocation()
        case .denied, .restricted:
            authorized = false
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD location=denied\n".utf8))
            computeAndBroadcast()
        default:
            break
        }
    }

    private func startMoodTimer() {
        moodTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.timerFired() }
        }
    }

    private func timerFired() {
        computeAndBroadcast()
        if let (lat, lon) = effectiveLatLon() {
            Task { await fetchWeatherIfNeeded(lat: lat, lon: lon) }
        }
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.computeAndBroadcast()
                if let (lat, lon) = self.effectiveLatLon() {
                    await self.fetchWeatherIfNeeded(lat: lat, lon: lon)
                }
                // FIX 10: only call requestLocation for .normal mode (has CLLocationManager).
                if self.mode == .normal && self.authorized {
                    self.locationManager?.requestLocation()
                }
            }
        }
    }

    private func effectiveLatLon() -> (lat: Double, lon: Double)? {
        if let ll = lastLocationLatLon { return ll }
        return AppStorageManager.readLatLon()
    }

    // FIX 2: synthesize 6:00/18:00 local time as fallback sun times.
    nonisolated static func synthesizeSunTimes(referenceEpoch: Double) -> (sunrise: Double, sunset: Double) {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let refDate = Date(timeIntervalSince1970: referenceEpoch)
        var srComps = cal.dateComponents([.year, .month, .day], from: refDate)
        srComps.hour = 6; srComps.minute = 0; srComps.second = 0
        var ssComps = srComps
        ssComps.hour = 18
        let sr = cal.date(from: srComps)?.timeIntervalSince1970 ?? (referenceEpoch - referenceEpoch.truncatingRemainder(dividingBy: 86400) + 6 * 3600)
        let ss = cal.date(from: ssComps)?.timeIntervalSince1970 ?? (referenceEpoch - referenceEpoch.truncatingRemainder(dividingBy: 86400) + 18 * 3600)
        return (sr, ss)
    }

    private func computeAndBroadcast() {
        let now = Date().timeIntervalSince1970
        let weather = resolveWeather(now: now)

        let srEpoch: Double
        let ssEpoch: Double
        if let w = weather, w.sunriseEpoch.isFinite, w.sunsetEpoch.isFinite, w.sunsetEpoch > w.sunriseEpoch,
           now >= w.sunriseEpoch && now < w.sunriseEpoch + 86400 {
            srEpoch = w.sunriseEpoch
            ssEpoch = w.sunsetEpoch
        } else {
            let synTimes = MoodController.synthesizeSunTimes(referenceEpoch: now)
            srEpoch = synTimes.sunrise
            ssEpoch = synTimes.sunset
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD sun=default\n".utf8))
        }

        let params = moodParams(
            nowEpoch: now,
            sunriseEpoch: srEpoch,
            sunsetEpoch: ssEpoch,
            weather: weather.map { e in
                let code = effectiveWeatherCode ?? e.weatherCode
                return WeatherInput(weatherCode: code,
                                    cloudCover: e.cloudCover,
                                    precipitation: e.precipitation)
            }
        )
        onMoodUpdate?(params)
    }

    private func resolveWeather(now: Double) -> WeatherCacheEntry? {
        guard let cache = currentCache else { return nil }
        let age = now - cache.fetchedAt
        if age > 21600 {
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD mood=stale age=\(Int(age))\n".utf8))
            return nil
        }
        if let (lat, lon) = effectiveLatLon() {
            if abs(cache.lat - lat) > 0.15 || abs(cache.lon - lon) > 0.15 {
                FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD mood=stale reason=location-mismatch\n".utf8))
                return nil
            }
        }
        return cache
    }

    // Pure helper: determines whether a new weather fetch should fire.
    // Returns true if: never attempted, OR genuinely moved (>0.15 deg), OR 900s have elapsed.
    nonisolated static func shouldFetch(
        now: Double,
        lastAttempt: Double,
        lastAttemptLatLon: (lat: Double, lon: Double)?,
        currentLatLon: (lat: Double, lon: Double)
    ) -> Bool {
        if let prev = lastAttemptLatLon {
            if abs(prev.lat - currentLatLon.lat) > 0.15 || abs(prev.lon - currentLatLon.lon) > 0.15 {
                return true
            }
        }
        return lastAttempt == 0 || now - lastAttempt >= 900
    }

    nonisolated static func shouldFetchOrForced(
        forced: Bool,
        now: Double,
        lastAttempt: Double,
        lastAttemptLatLon: (lat: Double, lon: Double)?,
        currentLatLon: (lat: Double, lon: Double)
    ) -> Bool {
        if forced { return true }
        return shouldFetch(now: now, lastAttempt: lastAttempt, lastAttemptLatLon: lastAttemptLatLon, currentLatLon: currentLatLon)
    }

    // FIX 3 + FIX 10: allow .noPlist mode to fetch; only block .hook.
    private func fetchWeatherIfNeeded(lat: Double, lon: Double, forced: Bool = false) async {
        guard mode != .hook else { return }
        let now = Date().timeIntervalSince1970
        guard MoodController.shouldFetchOrForced(
            forced: forced,
            now: now,
            lastAttempt: lastFetchedAt,
            lastAttemptLatLon: lastAttemptLatLon,
            currentLatLon: (lat, lon)
        ) else { return }
        await fetchWeather(lat: lat, lon: lon)
    }

    nonisolated static func openMeteoURL(lat: Double, lon: Double) -> String {
        return "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&timezone=auto&timeformat=unixtime&forecast_days=1&current=weather_code,cloud_cover,precipitation,is_day&daily=sunrise,sunset"
    }

    private func fetchWeather(lat: Double, lon: Double) async {
        let lat2 = (lat * 100).rounded() / 100
        let lon2 = (lon * 100).rounded() / 100
        lastFetchedAt = Date().timeIntervalSince1970
        lastAttemptLatLon = (lat2, lon2)
        guard let url = URL(string: MoodController.openMeteoURL(lat: lat2, lon: lon2)) else { return }
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD src=\(sourceTag()) fetch url=\(url.absoluteString)\n".utf8))
        var req = URLRequest(url: url)
        req.setValue("OnlyWallpapers/1.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let env2 = ProcessInfo.processInfo.environment
        if let fakeFile = env2["OW_MOOD_FAKE_RESPONSE_FILE"], !fakeFile.isEmpty,
           let fileData = try? Data(contentsOf: URL(fileURLWithPath: fakeFile)) {
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD transport=fake\n".utf8))
            data = fileData
        } else {
            do {
                let (d, _) = try await URLSession.shared.data(for: req)
                FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD transport=network\n".utf8))
                data = d
            } catch {
                FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD src=\(sourceTag()) weather=fail error=\(error.localizedDescription)\n".utf8))
                computeAndBroadcast()
                return
            }
        }
        guard let parsed = MoodController.parseOpenMeteoResponse(data: data, lat: lat2, lon: lon2) else {
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD src=\(sourceTag()) weather=fail\n".utf8))
            computeAndBroadcast()
            return
        }
        currentCache = parsed
        effectiveWeatherCode = hysteresis.resolve(incomingCode: parsed.weatherCode)
        _ = AppStorageManager.writeWeatherCache(parsed)
        let age = 0
        FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD src=\(sourceTag()) weather=ok age=\(age)\n".utf8))
        computeAndBroadcast()
    }

    nonisolated static func parseOpenMeteoResponse(data: Data, lat: Double, lon: Double) -> WeatherCacheEntry? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = obj["current"] as? [String: Any],
              let daily = obj["daily"] as? [String: Any] else { return nil }
        func d(_ dict: [String: Any], _ k: String) -> Double? { (dict[k] as? NSNumber)?.doubleValue }
        func i(_ dict: [String: Any], _ k: String) -> Int? { (dict[k] as? NSNumber)?.intValue }
        guard let wc = i(current, "weather_code"),
              let cc = d(current, "cloud_cover"),
              let pr = d(current, "precipitation"),
              let sunriseArr = daily["sunrise"] as? [Any],
              let sunsetArr = daily["sunset"] as? [Any],
              let sunriseEpoch = (sunriseArr.first as? NSNumber)?.doubleValue,
              let sunsetEpoch = (sunsetArr.first as? NSNumber)?.doubleValue else { return nil }
        return WeatherCacheEntry(
            fetchedAt: Date().timeIntervalSince1970,
            lat: lat, lon: lon,
            sunriseEpoch: sunriseEpoch, sunsetEpoch: sunsetEpoch,
            weatherCode: wc, cloudCover: cc, precipitation: pr)
    }

    private func sourceTag() -> String {
        if lastLocationLatLon != nil { return "location" }
        if AppStorageManager.readLatLon() != nil { return "config" }
        return "time"
    }

    // Hook mode: compute from OW_MOOD_WEATHER_JSON fixture or time-only.
    private func applyHookMood(env: [String: String]) {
        var weather: WeatherInput?
        var sunrise: Double = 0
        var sunset: Double = 0
        var hookNowEpoch: Double = 0

        if let jsonStr = env["OW_MOOD_WEATHER_JSON"],
           let data = jsonStr.data(using: .utf8) {
            if let entry = MoodController.parseOpenMeteoResponse(data: data, lat: 0, lon: 0) {
                weather = WeatherInput(weatherCode: entry.weatherCode, cloudCover: entry.cloudCover, precipitation: entry.precipitation)
                sunrise = entry.sunriseEpoch
                sunset  = entry.sunsetEpoch
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let current = obj["current"] as? [String: Any],
               let t = (current["time"] as? NSNumber)?.doubleValue {
                hookNowEpoch = t
            }
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD mood=hook weather=fixture\n".utf8))
        } else {
            FileHandle.standardOutput.write(Data("ONLYWALLPAPERS_MOOD mood=hook weather=time-only\n".utf8))
        }

        let nowEpoch: Double = (hookNowEpoch > 0) ? hookNowEpoch : Date().timeIntervalSince1970

        // FIX 2: synthesize local 06:00/18:00 if no fixture provides sun times.
        if sunrise == 0 && sunset == 0 {
            let synTimes = MoodController.synthesizeSunTimes(referenceEpoch: nowEpoch)
            sunrise = synTimes.sunrise
            sunset = synTimes.sunset
        }

        let params = moodParams(nowEpoch: nowEpoch, sunriseEpoch: sunrise, sunsetEpoch: sunset, weather: weather)
        onMoodUpdate?(params)
    }

    deinit {
        moodTimer?.invalidate()
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }
}

// Separate delegate class: all methods nonisolated to satisfy CLLocationManagerDelegate.
// Properties are nonisolated(unsafe) because the class is @MainActor by default
// (from .defaultIsolation) but the callbacks are only ever written during init on the
// main actor, then read from nonisolated delegate callbacks that CoreLocation dispatches
// to the main thread (since the manager is created on the main thread).
private final class _LocationDelegate: NSObject, CLLocationManagerDelegate {
    nonisolated(unsafe) private let onLocationCb: (Double, Double) -> Void
    nonisolated(unsafe) private let onFailCb: (Error) -> Void
    nonisolated(unsafe) private let onAuthCb: (CLAuthorizationStatus) -> Void

    init(
        onLocation: @escaping (Double, Double) -> Void,
        onFail: @escaping (Error) -> Void,
        onAuth: @escaping (CLAuthorizationStatus) -> Void
    ) {
        self.onLocationCb = onLocation
        self.onFailCb = onFail
        self.onAuthCb = onAuth
        super.init()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        onLocationCb(lat, lon)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onFailCb(error)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthCb(manager.authorizationStatus)
    }
}
