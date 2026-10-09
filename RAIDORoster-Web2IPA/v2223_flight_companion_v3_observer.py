from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
s = CONTENT.read_text()

# Flight Companion V3 observation/shadow engine.
# Deliberately does not replace V2 control logic yet: first collect real-flight
# sensor evidence, then tune deterministic resolver thresholds from replay.
if "import CoreMotion" not in s:
    s = s.replace("import SwiftUI\n", "import SwiftUI\nimport CoreMotion\n", 1)

anchor = "struct TodayRouteMapCard: View {"
idx = s.find(anchor)
if idx < 0:
    raise RuntimeError("V3 insertion anchor missing")

if "final class FlightCompanionV3Observer" not in s:
    code = r'''
enum FlightV3EvidenceSource: String, Codable {
    case barometer, motionActivity, deviceMotion
}

enum FlightV3EvidenceKind: String, Codable {
    case relativeAltitude, activity, acceleration
}

struct FlightV3Evidence: Codable, Identifiable {
    var id = UUID()
    let timestamp: Date
    let source: FlightV3EvidenceSource
    let kind: FlightV3EvidenceKind
    let value: Double?
    let detail: String?
    let confidence: Double
}

actor FlightV3EvidenceLog {
    static let shared = FlightV3EvidenceLog()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let url: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("FlightCompanionV3", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("sensor-evidence.jsonl")
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func append(_ evidence: FlightV3Evidence) {
        guard var data = try? encoder.encode(evidence) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
    }

    func all() -> [FlightV3Evidence] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(FlightV3Evidence.self, from: Data($0))
        }
    }
}

@MainActor
final class FlightCompanionV3Observer: ObservableObject {
    static let shared = FlightCompanionV3Observer()

    @Published private(set) var available = false
    @Published private(set) var relativeAltitudeM: Double?
    @Published private(set) var pressureKPa: Double?
    @Published private(set) var climbRateFtMin: Double = 0
    @Published private(set) var activityText = "Unknown"
    @Published private(set) var activityConfidence = "unknown"
    @Published private(set) var shadowPhase = "Armed"
    @Published private(set) var sampleCount = 0

    private let altimeter = CMAltimeter()
    private let activity = CMMotionActivityManager()
    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "RAIDORoster.FlightCompanionV3"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var altitudeWindow: [(Date, Double)] = []
    private var started = false
    private var movementSince: Date?
    private var climbSince: Date?
    private var descentSince: Date?
    private var levelSince: Date?

    func startObservation() {
        guard !started else { return }
        started = true
        available = CMAltimeter.isRelativeAltitudeAvailable() || CMMotionActivityManager.isActivityAvailable()

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, _ in
                guard let data else { return }
                let t = Date()
                let altitude = data.relativeAltitude.doubleValue
                let pressure = data.pressure.doubleValue
                Task { @MainActor in
                    self?.ingestAltitude(time: t, altitudeM: altitude, pressureKPa: pressure)
                }
            }
        }

        if CMMotionActivityManager.isActivityAvailable() {
            activity.startActivityUpdates(to: queue) { [weak self] item in
                guard let item else { return }
                Task { @MainActor in self?.ingestActivity(item) }
            }
        }

        // Foreground-preferred confidence booster only. Never required by resolver.
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.20
            motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
                guard let data else { return }
                let magnitude = sqrt(data.userAcceleration.x * data.userAcceleration.x +
                                     data.userAcceleration.y * data.userAcceleration.y +
                                     data.userAcceleration.z * data.userAcceleration.z)
                guard magnitude >= 0.08 else { return }
                Task { @MainActor in self?.ingestAcceleration(magnitude) }
            }
        }
    }

    func stopObservation() {
        altimeter.stopRelativeAltitudeUpdates()
        activity.stopActivityUpdates()
        motion.stopDeviceMotionUpdates()
        started = false
    }

    private func ingestAltitude(time: Date, altitudeM: Double, pressureKPa: Double) {
        relativeAltitudeM = altitudeM
        self.pressureKPa = pressureKPa
        altitudeWindow.append((time, altitudeM))
        altitudeWindow.removeAll { time.timeIntervalSince($0.0) > 30 }

        if let first = altitudeWindow.first, let last = altitudeWindow.last,
           last.0.timeIntervalSince(first.0) >= 10 {
            let minutes = last.0.timeIntervalSince(first.0) / 60
            climbRateFtMin = ((last.1 - first.1) * 3.28084) / max(minutes, 0.01)
        }
        sampleCount += 1
        Task { await FlightV3EvidenceLog.shared.append(
            FlightV3Evidence(timestamp: time, source: .barometer, kind: .relativeAltitude,
                             value: altitudeM, detail: String(format: "pressure=%.3fkPa rate=%.0ffpm", pressureKPa, climbRateFtMin),
                             confidence: 0.8)) }
        evaluateShadow(now: time)
    }

    private func ingestActivity(_ item: CMMotionActivity) {
        var labels: [String] = []
        if item.stationary { labels.append("stationary") }
        if item.walking { labels.append("walking") }
        if item.running { labels.append("running") }
        if item.automotive { labels.append("automotive") }
        if item.cycling { labels.append("cycling") }
        activityText = labels.isEmpty ? "unknown" : labels.joined(separator: "+")
        switch item.confidence {
        case .high: activityConfidence = "high"
        case .medium: activityConfidence = "medium"
        default: activityConfidence = "low"
        }
        let c: Double = item.confidence == .high ? 0.9 : (item.confidence == .medium ? 0.6 : 0.3)
        sampleCount += 1
        Task { await FlightV3EvidenceLog.shared.append(
            FlightV3Evidence(timestamp: item.startDate, source: .motionActivity, kind: .activity,
                             value: nil, detail: activityText, confidence: c)) }
        evaluateShadow(now: Date())
    }

    private func ingestAcceleration(_ magnitude: Double) {
        Task { await FlightV3EvidenceLog.shared.append(
            FlightV3Evidence(timestamp: Date(), source: .deviceMotion, kind: .acceleration,
                             value: magnitude, detail: "userAcceleration magnitude", confidence: 0.5)) }
    }

    // Shadow-only deterministic resolver. It records a prediction but does not
    // drive the existing Flight Companion marker or phase.
    private func evaluateShadow(now: Date) {
        let moving = activityText.contains("automotive") || activityText == "unknown"
        if moving { movementSince = movementSince ?? now } else { movementSince = nil }

        if climbRateFtMin > 1000 { climbSince = climbSince ?? now } else { climbSince = nil }
        if climbRateFtMin < -500 { descentSince = descentSince ?? now } else { descentSince = nil }
        if abs(climbRateFtMin) < 300 { levelSince = levelSince ?? now } else { levelSince = nil }

        if let since = climbSince, now.timeIntervalSince(since) >= 15 {
            shadowPhase = "Airborne"
        } else if let since = descentSince, now.timeIntervalSince(since) >= 60,
                  shadowPhase == "Airborne" || shadowPhase == "Cruise" {
            shadowPhase = "Descent"
        } else if let since = levelSince, now.timeIntervalSince(since) >= 60,
                  shadowPhase == "Airborne" {
            shadowPhase = "Cruise"
        } else if let since = movementSince, now.timeIntervalSince(since) >= 20,
                  shadowPhase == "Armed" {
            shadowPhase = "Ground movement"
        }
    }

    var diagnosticText: String {
        [
            "version=2.23.1-v3-shadow-observer",
            "available=\(available)",
            "samples=\(sampleCount)",
            "activity=\(activityText)",
            "activityConfidence=\(activityConfidence)",
            "relativeAltitudeM=\(relativeAltitudeM.map { String(format: "%.1f", $0) } ?? "none")",
            "pressureKPa=\(pressureKPa.map { String(format: "%.3f", $0) } ?? "none")",
            "baroRateFtMin=\(String(format: "%.0f", climbRateFtMin))",
            "shadowPhase=\(shadowPhase)",
            "mode=observe-only"
        ].joined(separator: "\n")
    }
}

'''
    s = s[:idx] + code + s[idx:]

# Start observation inside the existing ContentView onAppear closure created by
# the preceding V3 shadow patch. Anchoring to the shadow-engine startup avoids
# inserting a second SwiftUI modifier in the middle of a closure.
content_anchor = "struct ContentView: View {"
cv = s.find(content_anchor)
if cv < 0:
    raise RuntimeError("ContentView missing")
observer_start = "FlightCompanionV3Observer.shared.startObservation()"
if observer_start not in s:
    shadow_start = "            FlightCompanionV3ShadowEngine.shared.startShadowObservation()"
    pos = s.find(shadow_start, cv)
    if pos < 0:
        raise RuntimeError("V3 shadow startup anchor missing")
    s = s[:pos + len(shadow_start)] + "\n            " + observer_start + s[pos + len(shadow_start):]

for required in ["import CoreMotion", "final class FlightCompanionV3Observer", "CMAltimeter", "CMMotionActivityManager", "mode=observe-only"]:
    if required not in s:
        raise RuntimeError("V3 semantic guard missing: " + required)

s += "\n// V2.23.1 Flight Companion V3 sensor evidence observer (shadow mode)\n"
CONTENT.write_text(s)
print("Flight Companion V3 sensor observer applied")
