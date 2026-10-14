import CoreAudio
import Foundation

struct AudioFormatSignature: Equatable {
    let sampleRate: Double
    let format: AudioFormatID
    let flags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channels: UInt32
    let bits: UInt32

    init(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        self.format = format.mFormatID
        flags = format.mFormatFlags
        bytesPerPacket = format.mBytesPerPacket
        framesPerPacket = format.mFramesPerPacket
        bytesPerFrame = format.mBytesPerFrame
        channels = format.mChannelsPerFrame
        bits = format.mBitsPerChannel
    }
}

struct RouteTarget: Equatable {
    let processIDs: Set<AudioObjectID>
    let outputID: AudioObjectID
    let inputFormats: [AudioFormatSignature]
    let outputFormats: [AudioFormatSignature]
}

protocol RecoverableAudioRoute: AnyObject {
    func setGain(_ gain: Float)
    func stop()
    func isResponsive(playing: Bool, now: Date) -> Bool
}

struct RecoveryReport {
    var active: Set<String> = []
    var errors: [String: String] = [:]
}

// Only the backend actor touches this coordinator. Desired app settings belong
// to the model/store; losing a route must never delete those settings.
final class RouteRecovery<Route: RecoverableAudioRoute> {
    private struct Entry {
        let target: RouteTarget
        let route: Route
    }
    private struct Retry {
        let target: RouteTarget
        let failures: Int
        let after: Date
        let message: String
    }
    private var entries: [String: Entry] = [:]
    private var retries: [String: Retry] = [:]
    private let create: (RouteTarget, Float) throws -> Route

    init(create: @escaping (RouteTarget, Float) throws -> Route) { self.create = create }

    func reconcile(settings: [String: AppVolume], targets: [String: RouteTarget],
                   playing: Set<String>, now: Date = Date()) -> RecoveryReport {
        let desired = settings.filter { $0.value.enabled }
        for key in Array(entries.keys) {
            guard let entry = entries[key] else { continue }
            if desired[key] == nil || targets[key] != entry.target
                || !entry.route.isResponsive(playing: playing.contains(key), now: now) {
                entries.removeValue(forKey: key)?.route.stop()
            }
        }
        retries = retries.filter { desired[$0.key] != nil && targets[$0.key] == $0.value.target }
        var report = RecoveryReport()
        for (key, value) in desired {
            guard let target = targets[key], !target.processIDs.isEmpty else { continue }
            if let entry = entries[key] {
                entry.route.setGain(value.gain)
                report.active.insert(key)
                continue
            }
            if let retry = retries[key], now < retry.after {
                report.errors[key] = retry.message
                continue
            }
            do {
                let route = try create(target, value.gain)
                entries[key] = Entry(target: target, route: route)
                retries.removeValue(forKey: key)
                report.active.insert(key)
            } catch {
                let failures = (retries[key]?.failures ?? 0) + 1
                let delay = min(16.0, pow(2, Double(min(failures, 4))))
                retries[key] = Retry(target: target, failures: failures,
                                     after: now.addingTimeInterval(delay), message: error.localizedDescription)
                report.errors[key] = error.localizedDescription
            }
        }
        return report
    }

    func gain(key: String, value: Float) { entries[key]?.route.setGain(value) }

    func stopAll() {
        for entry in entries.values { entry.route.stop() }
        entries.removeAll()
        retries.removeAll()
    }
}
