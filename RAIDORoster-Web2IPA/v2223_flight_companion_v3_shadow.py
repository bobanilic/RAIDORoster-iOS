from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster/ContentView.swift"
s = CONTENT.read_text()

# V3 is intentionally a shadow/observation engine first. It records offline sensor
# evidence and derives a deterministic shadow phase without taking control away from V2.
if "final class FlightCompanionV3ShadowEngine" in s:
    print("Flight Companion V3 shadow engine already present")
    raise SystemExit(0)

# CoreMotion is required for motion activity + barometric evidence.
if "import CoreMotion" not in s:
    s = s.replace("import SwiftUI\n", "import SwiftUI\nimport CoreMotion\nimport CoreLocation\n", 1)

marker = "\n// Flight Companion V3 offline-resilient shadow engine\n"
block = r'''
// MARK: - Flight Companion V3 offline-resilient shadow engine

private enum FCV3PositionTier: Int, Codable, Comparable {
    case estimated = 0, fused = 1, measured = 2
    static func < (lhs: FCV3PositionTier, rhs: FCV3PositionTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

private enum FCV3Phase: String, Codable {
    case armed, groundMovement, taxiOut, takeoffRoll, airborne, cruise, descent, taxiIn, complete
}

private enum FCV3EvidenceSource: String, Codable {
    case gnss, adsbServer, motionActivity, barometer, roster, manual
}

private enum FCV3EvidenceKind: String, Codable {
    case position, motion, pressureTrend, eventCandidate, rosterChange
}

private struct FCV3Evidence: Codable, Identifiable {
    var id = UUID()
    let t: Date
    let source: FCV3EvidenceSource
    let kind: FCV3EvidenceKind
    var confidence: Double
    var horizontalAccuracyM: Double?
    var speedMps: Double?
    var relativeAltitudeM: Double?
    var climbRateFtMin: Double?
    var activity: String?
    var note: String?
}

private actor FCV3EvidenceLog {
    private let url: URL
    private let encoder = JSONEncoder()
    private var lastPositionWrite: Date?

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("FlightCompanionV3", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("shadow-evidence.jsonl")
        encoder.dateEncodingStrategy = .secondsSince1970
    }

    func append(_ evidence: FCV3Evidence) {
        if evidence.kind == .position {
            if let lastPositionWrite, evidence.t.timeIntervalSince(lastPositionWrite) < 10 { return }
            lastPositionWrite = evidence.t
        }
        guard var line = try? encoder.encode(evidence) else { return }
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

@MainActor
private final class FlightCompanionV3ShadowEngine: ObservableObject {
    static let shared = FlightCompanionV3ShadowEngine()

    @Published private(set) var phase: FCV3Phase = .armed
    @Published private(set) var climbRateFtMin: Double = 0
    @Published private(set) var activityText = "unknown"
    @Published private(set) var evidenceCount = 0

    private let altimeter = CMAltimeter()
    private let activityManager = CMMotionActivityManager()
    private let log = FCV3EvidenceLog()
    private var altitudeSamples: [(Date, Double)] = []
    private var candidateSince: Date?
    private var enteredPhaseAt = Date()
    private var started = false

    func startShadowObservation() {
        guard !started else { return }
        started = true

        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.consumeAltitude(data.relativeAltitude.doubleValue, at: Date())
            }
        }

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let self, let activity else { return }
                let value: String
                if activity.automotive { value = "automotive" }
                else if activity.walking { value = "walking" }
                else if activity.running { value = "running" }
                else if activity.cycling { value = "cycling" }
                else if activity.stationary { value = "stationary" }
                else { value = "unknown" }
                self.activityText = value
                self.record(FCV3Evidence(t: Date(), source: .motionActivity, kind: .motion,
                    confidence: activity.confidence == .high ? 0.8 : (activity.confidence == .medium ? 0.55 : 0.3),
                    activity: value))
                self.evaluate(now: Date())
            }
        }
    }

    func recordGNSS(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        let accuracy = location.horizontalAccuracy
        let confidence: Double
        if accuracy <= 30 { confidence = 0.95 }
        else if accuracy <= 100 { confidence = 0.75 }
        else if accuracy <= 300 { confidence = 0.35 }
        else { return }
        record(FCV3Evidence(t: location.timestamp, source: .gnss, kind: .position,
            confidence: confidence, horizontalAccuracyM: accuracy,
            speedMps: location.speed >= 0 ? location.speed : nil))
    }

    private func consumeAltitude(_ meters: Double, at now: Date) {
        altitudeSamples.append((now, meters))
        altitudeSamples.removeAll { now.timeIntervalSince($0.0) > 30 }
        guard altitudeSamples.count >= 3,
              let first = altitudeSamples.first,
              let last = altitudeSamples.last else { return }
        let dt = last.0.timeIntervalSince(first.0)
        guard dt >= 10 else { return }
        climbRateFtMin = ((last.1 - first.1) * 3.28084) / (dt / 60.0)
        record(FCV3Evidence(t: now, source: .barometer, kind: .pressureTrend,
            confidence: min(0.95, 0.45 + min(abs(climbRateFtMin) / 2500.0, 0.5)),
            relativeAltitudeM: meters, climbRateFtMin: climbRateFtMin))
        evaluate(now: now)
    }

    private func evaluate(now: Date) {
        let moving = activityText == "automotive" || activityText == "unknown"
        let flat = abs(climbRateFtMin) < 300
        let climbing = climbRateFtMin > 1000
        let descending = climbRateFtMin < -500

        var proposed: FCV3Phase?
        var dwell: TimeInterval = 0
        switch phase {
        case .armed:
            if moving { proposed = .groundMovement; dwell = 20 }
        case .groundMovement:
            if moving && flat { proposed = .taxiOut; dwell = 15 }
        case .taxiOut:
            // Without foreground device-motion or measured speed, remain conservative.
            if climbing { proposed = .airborne; dwell = 15 }
        case .takeoffRoll:
            if climbing { proposed = .airborne; dwell = 15 }
        case .airborne:
            if abs(climbRateFtMin) < 300 { proposed = .cruise; dwell = 60 }
        case .cruise:
            if descending { proposed = .descent; dwell = 60 }
        case .descent:
            if flat && moving { proposed = .taxiIn; dwell = 30 }
        case .taxiIn:
            if activityText == "stationary" { proposed = .complete; dwell = 60 }
        case .complete:
            break
        }

        guard let proposed else { candidateSince = nil; return }
        if candidateSince == nil { candidateSince = now }
        if now.timeIntervalSince(candidateSince ?? now) >= dwell {
            phase = proposed
            enteredPhaseAt = now
            candidateSince = nil
            record(FCV3Evidence(t: now, source: .barometer, kind: .eventCandidate,
                confidence: 0.7, note: "shadow phase -> \(proposed.rawValue)"))
        }
    }

    private func record(_ evidence: FCV3Evidence) {
        evidenceCount += 1
        Task { await log.append(evidence) }
    }

    var diagnosticText: String {
        [
            "version=2.23.1-flight-companion-v3-shadow",
            "mode=observation-only",
            "phase=\(phase.rawValue)",
            "activity=\(activityText)",
            "baroFtMin=\(Int(climbRateFtMin.rounded()))",
            "evidence=\(evidenceCount)",
            "networkRequired=false-for-sensor-observation",
            "controlsLiveTracking=false"
        ].joined(separator: "\n")
    }
}
'''
s += marker + block

# Start observation with the app. This is shadow-only and cannot regress V2 phase/position.
needle = "TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items)"
idx = s.find(needle)
if idx >= 0:
    # Find the first onAppear containing the existing auto-arm call and add V3 once.
    line = "TodayLiveFlightLocationManager.shared.configureAutomaticFlight(from: appState.rosterStore.items)"
    s = s.replace(line, line + "\n            FlightCompanionV3ShadowEngine.shared.startShadowObservation()", 1)
else:
    raise RuntimeError("V3 could not find automatic Flight Companion startup anchor")

# Feed accepted GNSS into V3 evidence without changing V2 behavior.
needle2 = "evaluateAuto(now: Date(), location: candidate)"
if needle2 in s:
    s = s.replace(
        needle2,
        needle2 + "\n        Task { @MainActor in FlightCompanionV3ShadowEngine.shared.recordGNSS(candidate) }",
        1,
    )
else:
    needle2 = "evaluateAuto(now: Date(), location: newest)"
    if needle2 in s:
        s = s.replace(
            needle2,
            needle2 + "\n        Task { @MainActor in FlightCompanionV3ShadowEngine.shared.recordGNSS(newest) }",
            1,
        )

for required in [
    "final class FlightCompanionV3ShadowEngine",
    "CMAltimeter",
    "CMMotionActivityManager",
    "mode=observation-only",
    "startShadowObservation()"
]:
    if required not in s:
        raise RuntimeError("V3 semantic guard missing: " + required)

CONTENT.write_text(s)
print("Flight Companion V3 offline sensor shadow recorder applied")
