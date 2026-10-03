import Foundation

/// Cabin pressure and device motion provide phase evidence, never a measured position.
struct FlightSensorPolicy {
    enum Phase { case inactive, preflight, airborne }
    enum Event: Equatable { case takeoff(Date), landing(Date) }
    struct Thresholds {
        var smoothingSeconds = 2.5
        var burstBeginG = 0.10
        var burstEndG = 0.06
        var takeoffPeakG = 0.12
        var takeoffBurstSeconds = 15.0
        var climbFtMin = 150.0
        var climbSeconds = 45.0
        var landingBurstSeconds = 8.0
        var descentFtMin = -150.0
        var descentSeconds = 120.0
        var flatFtMin = 100.0
        var flatSeconds = 5.0
        var motionGapSeconds = 1.0
        var altitudeGapSeconds = 5.0
        var maximumDeliveryDelay = 2.0
        var descentLifetime = 10.0 * 60
    }
    private struct Burst {
        let start: Date
        let end: Date
        let peak: Double
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }
    let thresholds: Thresholds
    private(set) var phase: Phase = .inactive
    private(set) var smoothedAcceleration = 0.0
    private(set) var climbRateFtMin: Double?
    private(set) var rejectedSamples = 0
    private var lastMotionAt: Date?
    private var lastAltitudeAt: Date?
    private var altitudes: [(Date, Double)] = []
    private var burstStart: Date?
    private var burstPeak = 0.0
    private var ignoreBurstUntil: Date?
    private var burst: Burst?
    private var climbSince: Date?
    private var descentSince: Date?
    private var descentEvidenceAt: Date?
    private var flatSince: Date?

    init(thresholds: Thresholds = Thresholds()) { self.thresholds = thresholds }

    mutating func reset(to phase: Phase = .inactive) {
        self = FlightSensorPolicy(thresholds: thresholds)
        self.phase = phase
    }

    mutating func setPhase(_ value: Phase) {
        if phase != value { reset(to: value) }
    }

    static func sampleDate(uptime: TimeInterval, receivedAt: Date, currentUptime: TimeInterval) -> Date? {
        let age = currentUptime - uptime
        guard age.isFinite, age >= 0, age <= 2 else { return nil }
        return receivedAt.addingTimeInterval(-age)
    }

    private func timely(_ sample: Date, receivedAt: Date) -> Bool {
        let age = receivedAt.timeIntervalSince(sample)
        return age.isFinite && age >= 0 && age <= thresholds.maximumDeliveryDelay
    }

    mutating func ingestMotion(_ magnitude: Double, at time: Date, receivedAt: Date) -> Event? {
        guard phase != .inactive, magnitude.isFinite, magnitude >= 0, timely(time, receivedAt: receivedAt),
              lastMotionAt.map({ time > $0 }) ?? true else {
            rejectedSamples += 1
            return nil
        }
        let dt = lastMotionAt.map { time.timeIntervalSince($0) } ?? 0.2
        if dt > thresholds.motionGapSeconds {
            smoothedAcceleration = 0
            burstStart = nil; burstPeak = 0; burst = nil; climbSince = nil
            // A missed roll/braking interval is not continuous evidence.
        }
        lastMotionAt = time
        let alpha = 1 - exp(-min(dt, thresholds.motionGapSeconds) / thresholds.smoothingSeconds)
        smoothedAcceleration += alpha * (magnitude - smoothedAcceleration)
        if let until = ignoreBurstUntil, time < until { return evaluate(at: time) }
        ignoreBurstUntil = nil
        if let start = burstStart {
            burstPeak = max(burstPeak, smoothedAcceleration)
            if time.timeIntervalSince(start) > 150 {
                burstStart = nil; burstPeak = 0; burst = nil
                ignoreBurstUntil = time.addingTimeInterval(60)
            } else if smoothedAcceleration < thresholds.burstEndG {
                burst = Burst(start: start, end: time, peak: burstPeak)
                burstStart = nil; burstPeak = 0; climbSince = nil
            }
        } else if smoothedAcceleration >= thresholds.burstBeginG {
            burstStart = time; burstPeak = smoothedAcceleration
        }
        return evaluate(at: time)
    }

    mutating func ingestAltitude(_ altitudeM: Double, at time: Date, receivedAt: Date) -> Event? {
        guard phase != .inactive, altitudeM.isFinite, timely(time, receivedAt: receivedAt),
              lastAltitudeAt.map({ time > $0 }) ?? true else {
            rejectedSamples += 1
            return nil
        }
        if let previous = lastAltitudeAt, time.timeIntervalSince(previous) > thresholds.altitudeGapSeconds {
            altitudes = []; climbRateFtMin = nil
            climbSince = nil; descentSince = nil; descentEvidenceAt = nil; flatSince = nil
            burst = nil; burstStart = nil; burstPeak = 0 // Never join evidence across suspension.
        }
        lastAltitudeAt = time
        altitudes.append((time, altitudeM))
        altitudes.removeAll { time.timeIntervalSince($0.0) > 30 }
        guard let first = altitudes.first, time.timeIntervalSince(first.0) >= 10 else {
            climbRateFtMin = nil
            return nil
        }
        let rate = (altitudeM - first.1) * 3.28084 * 60 / time.timeIntervalSince(first.0)
        climbRateFtMin = rate
        // Only new barometer samples advance pressure timers.
        if phase == .preflight, let burst, time >= burst.end, rate >= thresholds.climbFtMin {
            climbSince = climbSince ?? time
        } else { climbSince = nil }
        if phase == .airborne, rate <= thresholds.descentFtMin {
            descentSince = descentSince ?? time
            if time.timeIntervalSince(descentSince ?? time) >= thresholds.descentSeconds { descentEvidenceAt = time }
        } else { descentSince = nil }
        if abs(rate) < thresholds.flatFtMin { flatSince = flatSince ?? time } else { flatSince = nil }
        // A sustained renewed climb invalidates a previous approach/go-around.
        if phase == .airborne, rate >= thresholds.climbFtMin { descentEvidenceAt = nil }
        return evaluate(at: time)
    }

    private func evaluate(at time: Date) -> Event? {
        guard let motionAt = lastMotionAt, let altitudeAt = lastAltitudeAt,
              (0...thresholds.motionGapSeconds).contains(time.timeIntervalSince(motionAt)),
              (0...thresholds.altitudeGapSeconds).contains(time.timeIntervalSince(altitudeAt)),
              let burst else { return nil }
        if phase == .preflight, burst.duration >= thresholds.takeoffBurstSeconds,
           burst.peak >= thresholds.takeoffPeakG,
           (0...360).contains(time.timeIntervalSince(burst.end)),
           let since = climbSince, since >= burst.end,
           altitudeAt.timeIntervalSince(since) >= thresholds.climbSeconds {
            return .takeoff(burst.end)
        }
        if phase == .airborne, burst.duration >= thresholds.landingBurstSeconds,
           (0...120).contains(time.timeIntervalSince(burst.end)),
           let descent = descentEvidenceAt, burst.start >= descent,
           (0...thresholds.descentLifetime).contains(time.timeIntervalSince(descent)),
           let flat = flatSince, altitudeAt.timeIntervalSince(flat) >= thresholds.flatSeconds {
            return .landing(burst.start)
        }
        return nil
    }
}

enum FlightSensorSessionPolicy {
    static func cruiseSpeed(distance: Double, departure: Date?, arrival: Date?) -> Double {
        guard distance.isFinite, distance > 1_000, let departure, let arrival, arrival > departure else { return 220 }
        return min(250, max(110, distance / max(20 * 60, arrival.timeIntervalSince(departure) - 18 * 60)))
    }

    static func arrivalWindow(takeoff: Date, departure: Date?, arrival: Date?, now: Date) -> Bool {
        guard now >= takeoff, now.timeIntervalSince(takeoff) <= 18 * 60 * 60 else { return false }
        guard let departure, let arrival, arrival > departure else { return true }
        // Follow actual takeoff when departure is delayed; do not use the departure-only gate at arrival.
        let expected = max(arrival, takeoff.addingTimeInterval(arrival.timeIntervalSince(departure)))
        return now <= expected.addingTimeInterval(2 * 60 * 60)
    }

    static func canLand(takeoff: Date?, departure: Date?, arrival: Date?, progress: Double?,
                        conflictingMeasurement: Bool, now: Date) -> Bool {
        guard let takeoff, now.timeIntervalSince(takeoff) >= 12 * 60,
              arrivalWindow(takeoff: takeoff, departure: departure, arrival: arrival, now: now),
              let progress, progress.isFinite, progress >= 0.70, progress <= 1,
              !conflictingMeasurement else { return false }
        return true
    }
}
