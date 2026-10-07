import Foundation

struct MoodParams: Equatable {
    var brightness: Double
    var saturate: Double
    var contrast: Double
    var hueRotate: Double
    var sepia: Double

    static let neutral = MoodParams(brightness: 1.01, saturate: 1.0, contrast: 1.01, hueRotate: 0, sepia: 0)
}

struct WeatherInput: Equatable {
    let weatherCode: Int
    let cloudCover: Double   // raw 0..100 from API
    let precipitation: Double
}

enum WeatherGroup: Equatable {
    case clear, cloudy, fog, rain, storm, snow

    nonisolated init(code: Int) {
        switch code {
        case 45, 48:           self = .fog
        case 51...67, 80...82: self = .rain
        case 71...77, 85, 86:  self = .snow
        case 95...99:          self = .storm
        case 1...3:            self = .cloudy
        default:               self = .clear
        }
    }
}

// Pure, nonisolated: call from any context.
nonisolated func moodParams(
    nowEpoch: Double,
    sunriseEpoch: Double,
    sunsetEpoch: Double,
    weather: WeatherInput?
) -> MoodParams {
    let span = sunsetEpoch - sunriseEpoch
    guard span > 0, sunriseEpoch.isFinite, sunsetEpoch.isFinite else {
        // Polar guard: sunset <= sunrise or non-finite -> neutral, no divide.
        return applyOffsets(
            MoodParams(brightness: 1.01, saturate: 1.0, contrast: 1.03, hueRotate: 0, sepia: 0),
            weather: weather)
    }

    let t = (nowEpoch - sunriseEpoch) / span

    let B: Double
    let S: Double
    let C: Double = 1.05
    let H: Double = 0
    let Se: Double

    if t < 0 || t > 1 {
        // Night: cool + dim, no sepia.
        B = 0.92; S = 0.80; Se = 0.0
    } else {
        let sinT = sin(Double.pi * t)
        let cosT = cos(Double.pi * t)
        B = 0.92 + 0.13 * sinT        // dawn/dusk=0.92, noon=1.05
        S = 0.90 + 0.20 * sinT        // dawn/dusk=0.90, noon=1.10
        Se = 0.08 * cosT * cosT       // dawn=0.08, noon=0.0, dusk=0.08
    }

    return applyOffsets(MoodParams(brightness: B, saturate: S, contrast: C, hueRotate: H, sepia: Se),
                        weather: weather)
}

private nonisolated func applyOffsets(_ base: MoodParams, weather: WeatherInput?) -> MoodParams {
    var B = base.brightness
    var S = base.saturate
    var C = base.contrast
    var Se = base.sepia

    if let w = weather {
        let cloud = min(max(w.cloudCover / 100.0, 0), 1)
        S -= 0.2 * cloud
        B -= 0.08 * cloud

        // FIX 8: precipitation additive desaturate+dim regardless of WMO code.
        // Normalize to [0,1] with 50mm/h as the heavy ceiling.
        let precip = min(max(w.precipitation / 50.0, 0), 1)
        S -= 0.10 * precip
        B -= 0.04 * precip

        switch WeatherGroup(code: w.weatherCode) {
        case .fog:   C -= 0.05
        case .rain:  S -= 0.08; B -= 0.04
        case .storm: S -= 0.15; B -= 0.08
        case .snow:  B += 0.05; S -= 0.05
        case .clear, .cloudy: break
        }
    }

    B  = min(max(B,  0.85), 1.08)
    S  = min(max(S,  0.70), 1.15)
    C  = min(max(C,  1.00), 1.15)
    Se = min(max(Se, 0.00), 0.12)
    if C < 1.01 { C = 1.01 }   // live-floor: filter is always active

    return MoodParams(brightness: B, saturate: S, contrast: C, hueRotate: base.hueRotate, sepia: Se)
}

// Always emits exactly 5 functions in the same order.
nonisolated func cssFilter(_ params: MoodParams) -> String {
    func r4(_ x: Double) -> String { String(format: "%.4f", x) }
    return "brightness(\(r4(params.brightness))) saturate(\(r4(params.saturate))) contrast(\(r4(params.contrast))) hue-rotate(\(r4(params.hueRotate))deg) sepia(\(r4(params.sepia)))"
}

struct WeatherHysteresis {
    var appliedGroup: WeatherGroup? = nil
    var consecutiveDisagrees: Int = 0

    mutating func resolve(incomingCode: Int) -> Int {
        let incomingGroup = WeatherGroup(code: incomingCode)
        if appliedGroup == nil {
            appliedGroup = incomingGroup
            consecutiveDisagrees = 0
            return incomingCode
        }
        if incomingGroup == appliedGroup {
            consecutiveDisagrees = 0
            return incomingCode
        }
        consecutiveDisagrees += 1
        if consecutiveDisagrees >= 2 {
            appliedGroup = incomingGroup
            consecutiveDisagrees = 0
            return incomingCode
        }
        return representativeCode(for: appliedGroup!)
    }

    private func representativeCode(for group: WeatherGroup) -> Int {
        switch group {
        case .clear:  return 0
        case .cloudy: return 3
        case .fog:    return 45
        case .rain:   return 61
        case .storm:  return 95
        case .snow:   return 71
        }
    }
}
