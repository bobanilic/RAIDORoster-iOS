@MainActor
final class FlightCompanionV3Observer: ObservableObject {
    static let shared = FlightCompanionV3Observer()
    @Published private(set) var available = false
    @Published private(set) var relativeAltitudeM: Double?
    @Published private(set) var pressureKPa: Double?
    @Published private(set) var climbRateFtMin: Double = 0
    @Published private(set) var sampleCount = 0
    private let altimeter = CMAltimeter()
    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "RAIDORoster.FlightCompanionV3"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1
        return q
    }()
    // All tunable thresholds live in FlightSensorPolicy.Thresholds.
    private var policy = FlightSensorPolicy()
    private var epoch = UUID()
    private var started = false
    private var sessionKey: String?
    private var pendingEvidence: [FlightV3Evidence] = []
    private var lastFlushAt: Date?

    func startObservation(sessionKey key: String) {
        if started, sessionKey == key { return }
        stopObservation()
        sessionKey = key
        started = true
        let generation = epoch
        policy.setPhase(TodayLiveFlightLocationManager.shared.sensorPhase)
        available = CMAltimeter.isRelativeAltitudeAvailable() && motion.isDeviceMotionAvailable
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, error in
                let received = Date(), uptime = ProcessInfo.processInfo.systemUptime
                guard let data else {
                    Task { @MainActor in self?.sensorFailed(generation: generation, detail: "barometer unavailable") }
                    return
                }
                let timestamp = data.timestamp
                let altitude = data.relativeAltitude.doubleValue
                let pressure = data.pressure.doubleValue
                Task { @MainActor in
                    guard let self, self.started, self.epoch == generation else { return }
                    guard let time = FlightSensorPolicy.sampleDate(uptime: timestamp, receivedAt: received, currentUptime: uptime),
                          Date().timeIntervalSince(time) <= 2 else {
                        self.sensorFailed(generation: generation, detail: "delayed barometer sample")
                        return
                    }
                    self.ingestAltitude(time: time, altitude: altitude, pressure: pressure)
                }
            }
        }
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.20
            motion.startDeviceMotionUpdates(to: queue) { [weak self] data, error in
                let received = Date(), uptime = ProcessInfo.processInfo.systemUptime
                guard let data else {
                    Task { @MainActor in self?.sensorFailed(generation: generation, detail: "motion unavailable") }
                    return
                }
                let timestamp = data.timestamp
                let a = data.userAcceleration
                let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                Task { @MainActor in
                    guard let self, self.started, self.epoch == generation else { return }
                    guard let time = FlightSensorPolicy.sampleDate(uptime: timestamp, receivedAt: received, currentUptime: uptime),
                          Date().timeIntervalSince(time) <= 2 else {
                        self.sensorFailed(generation: generation, detail: "delayed motion sample")
                        return
                    }
                    self.ingestMotion(time: time, magnitude: magnitude)
                }
            }
        }
        record(.init(timestamp: Date(), source: .deviceMotion, kind: .activity, value: nil,
                     detail: "sensor session started", confidence: 1), force: true)
    }

    func stopObservation() {
        epoch = UUID() // Drop callbacks queued by the previous sector/session.
        altimeter.stopRelativeAltitudeUpdates()
        motion.stopDeviceMotionUpdates()
        flushEvidence()
        started = false
        available = false
        sessionKey = nil
        policy.reset()
        relativeAltitudeM = nil; pressureKPa = nil; climbRateFtMin = 0
    }

    private func sensorFailed(generation: UUID, detail: String) {
        guard started, epoch == generation else { return }
        policy.reset(to: TodayLiveFlightLocationManager.shared.sensorPhase)
        climbRateFtMin = 0
        record(.init(timestamp: Date(), source: .deviceMotion, kind: .activity,
                     value: nil, detail: detail, confidence: 0), force: true)
    }

    private func ingestMotion(time: Date, magnitude: Double) {
        let manager = TodayLiveFlightLocationManager.shared
        policy.setPhase(manager.sensorPhase)
        let event = policy.ingestMotion(magnitude, at: time, receivedAt: Date())
        record(.init(timestamp: time, source: .deviceMotion, kind: .acceleration,
                     value: magnitude, detail: "userAcceleration magnitude g", confidence: 0.5))
        handle(event)
    }

    private func ingestAltitude(time: Date, altitude: Double, pressure: Double) {
        let manager = TodayLiveFlightLocationManager.shared
        policy.setPhase(manager.sensorPhase)
        relativeAltitudeM = altitude; pressureKPa = pressure
        let event = policy.ingestAltitude(altitude, at: time, receivedAt: Date())
        climbRateFtMin = policy.climbRateFtMin ?? 0
        record(.init(timestamp: time, source: .barometer, kind: .relativeAltitude, value: altitude,
                     detail: "pressure=\(pressure)kPa rate=\(policy.climbRateFtMin.map(String.init(describing:)) ?? "unknown")fpm",
                     confidence: policy.climbRateFtMin == nil ? 0 : 0.8))
        handle(event)
    }

    private func handle(_ event: FlightSensorPolicy.Event?) {
        guard let event else { return }
        let manager = TodayLiveFlightLocationManager.shared
        let accepted: Bool
        switch event {
        case .takeoff(let at): accepted = manager.sensorTakeoffDetected(burstEnd: at, now: Date())
        case .landing(let at): accepted = manager.sensorLandingDetected(at: at, now: Date())
        }
        record(.init(timestamp: Date(), source: .deviceMotion, kind: .activity, value: nil,
                     detail: "candidate=\(event) accepted=\(accepted)", confidence: accepted ? 0.8 : 0), force: true)
        if accepted { policy.reset(to: manager.sensorPhase) }
    }

    private func record(_ value: FlightV3Evidence, force: Bool = false) {
        sampleCount += 1
        pendingEvidence.append(value)
        let now = Date()
        if force || pendingEvidence.count >= 64 || lastFlushAt.map({ now.timeIntervalSince($0) >= 5 }) ?? true {
            flushEvidence()
        }
    }

    private func flushEvidence() {
        guard !pendingEvidence.isEmpty else { return }
        let batch = pendingEvidence
        pendingEvidence.removeAll(keepingCapacity: true)
        lastFlushAt = Date()
        Task { await FlightV3EvidenceLog.shared.appendBatch(batch) }
    }

    var diagnosticText: String {
        ["version=2.26.0-sensor-driver", "observing=\(started)", "available=\(available)",
         "samples=\(sampleCount)", "rejectedSamples=\(policy.rejectedSamples)",
         "baroRateFtMin=\(policy.climbRateFtMin.map(String.init(describing:)) ?? "unknown")",
         "smoothedAccelG=\(String(format: "%.3f", policy.smoothedAcceleration))",
         "mode=drives-phase-offline"].joined(separator: "\n")
    }
}
