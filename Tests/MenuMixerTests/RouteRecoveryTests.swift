import Foundation
import CoreAudio

private final class FakeRoute: RecoverableAudioRoute {
    var gain: Float
    var stopped = false
    var responsive = true
    init(gain: Float) { self.gain = gain }
    func setGain(_ gain: Float) { self.gain = gain }
    func stop() { stopped = true }
    func isResponsive(playing: Bool, now: Date) -> Bool { !playing || responsive }
}

final class RouteRecoveryTests {
    private let chrome = "com.google.Chrome"
    private let time = Date(timeIntervalSince1970: 1000)

    private func target(output: UInt32 = 10, processes: Set<UInt32> = [1],
                        rate: Double = 48000, channels: UInt32 = 2) -> RouteTarget {
        let format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        return RouteTarget(processIDs: processes, outputID: output,
                           inputFormats: [], outputFormats: [AudioFormatSignature(format)])
    }

    func testChromeMuteSurvivesDiscordCallModeEntryAndExit() {
        var routes: [FakeRoute] = []
        let recovery = RouteRecovery<FakeRoute> { _, gain in
            let route = FakeRoute(gain: gain); routes.append(route); return route
        }
        let saved = [chrome: AppVolume(volume: 0.7, muted: true, enabled: true)]
        // AirPods can change rate/channel layout without changing AudioObjectID.
        for (index, layout) in [target(), target(rate: 24000, channels: 1), target()].enumerated() {
            let report = recovery.reconcile(settings: saved, targets: [chrome: layout],
                                            playing: [chrome], now: time.addingTimeInterval(Double(index)))
            expectEqual(report.active, [chrome])
            expectEqual(routes.last?.gain, 0)
            expectTrue(saved[chrome]!.enabled)
            expectTrue(saved[chrome]!.muted)
        }
        expectEqual(routes.count, 3)
        expectTrue(routes[0].stopped)
        expectTrue(routes[1].stopped)
        expectFalse(routes[2].stopped)
    }

    func testChannelCountChangeAtSameRateAlsoRebuilds() {
        var creations = 0
        let recovery = RouteRecovery<FakeRoute> { _, gain in creations += 1; return FakeRoute(gain: gain) }
        let saved = [chrome: AppVolume(volume: 0, enabled: true)]
        _ = recovery.reconcile(settings: saved, targets: [chrome: target()], playing: [chrome], now: time)
        let report = recovery.reconcile(settings: saved, targets: [chrome: target(channels: 1)], playing: [chrome], now: time)
        expectEqual(creations, 2)
        expectEqual(report.active, [chrome])
    }

    func testDifferentOutputRestoresAttenuation() {
        var routes: [FakeRoute] = []
        let recovery = RouteRecovery<FakeRoute> { _, gain in
            let route = FakeRoute(gain: gain); routes.append(route); return route
        }
        let saved = [chrome: AppVolume(volume: 0.2, enabled: true)]
        _ = recovery.reconcile(settings: saved, targets: [chrome: target()], playing: [chrome], now: time)
        let report = recovery.reconcile(settings: saved, targets: [chrome: target(output: 11)], playing: [chrome], now: time)
        expectEqual(report.active, [chrome])
        expectTrue(routes[0].stopped)
        expectEqual(routes[1].gain, 0.2, accuracy: 0.0001)
    }

    func testHelperDisappearsThenNewProcessReturnsWithSameMute() {
        var routes: [FakeRoute] = []
        let recovery = RouteRecovery<FakeRoute> { _, gain in
            let route = FakeRoute(gain: gain); routes.append(route); return route
        }
        let saved = [chrome: AppVolume(muted: true, enabled: true)]
        _ = recovery.reconcile(settings: saved, targets: [chrome: target()], playing: [chrome], now: time)
        expectTrue(recovery.reconcile(settings: saved, targets: [:], playing: [], now: time).active.isEmpty)
        expectTrue(routes[0].stopped)
        let report = recovery.reconcile(settings: saved, targets: [chrome: target(processes: [8, 9])], playing: [chrome], now: time)
        expectEqual(report.active, [chrome])
        expectEqual(routes.last?.gain, 0)
        expectEqual(routes.count, 2)
    }

    func testFailedReconnectionRetriesWithoutLosingPreference() {
        struct TemporaryFailure: Error {}
        var attempts = 0
        var created: FakeRoute?
        let recovery = RouteRecovery<FakeRoute> { _, gain in
            attempts += 1
            if attempts == 1 { throw TemporaryFailure() }
            let route = FakeRoute(gain: gain); created = route; return route
        }
        let saved = [chrome: AppVolume(muted: true, enabled: true)]
        let targets = [chrome: target()]
        let failed = recovery.reconcile(settings: saved, targets: targets, playing: [chrome], now: time)
        expectTrue(failed.active.isEmpty)
        expectNotNil(failed.errors[chrome])
        _ = recovery.reconcile(settings: saved, targets: targets, playing: [chrome], now: time.addingTimeInterval(1))
        expectEqual(attempts, 1)
        let restored = recovery.reconcile(settings: saved, targets: targets, playing: [chrome], now: time.addingTimeInterval(2))
        expectEqual(attempts, 2)
        expectEqual(restored.active, [chrome])
        expectEqual(created?.gain, 0)
    }

    func testNewDeviceBypassesOldDeviceRetryDelay() {
        struct TemporaryFailure: Error {}
        var attempts = 0
        let recovery = RouteRecovery<FakeRoute> { target, gain in
            attempts += 1
            if target.outputID == 10 { throw TemporaryFailure() }
            return FakeRoute(gain: gain)
        }
        let saved = [chrome: AppVolume(enabled: true)]
        _ = recovery.reconcile(settings: saved, targets: [chrome: target()], playing: [], now: time)
        let restored = recovery.reconcile(settings: saved, targets: [chrome: target(output: 11)], playing: [], now: time)
        expectEqual(attempts, 2)
        expectEqual(restored.active, [chrome])
    }

    func testExplicitDisableCancelsPendingRecovery() {
        var routes: [FakeRoute] = []
        let recovery = RouteRecovery<FakeRoute> { _, gain in
            let route = FakeRoute(gain: gain); routes.append(route); return route
        }
        var saved = [chrome: AppVolume(muted: true, enabled: true)]
        _ = recovery.reconcile(settings: saved, targets: [chrome: target()], playing: [], now: time)
        _ = recovery.reconcile(settings: saved, targets: [:], playing: [], now: time)
        saved[chrome]?.enabled = false
        let report = recovery.reconcile(settings: saved, targets: [chrome: target()], playing: [], now: time)
        expectTrue(report.active.isEmpty)
        expectEqual(routes.count, 1)
        expectTrue(routes[0].stopped)
    }

    func testIdleDoesNotRebuildButStalledPlaybackDoes() {
        var routes: [FakeRoute] = []
        let recovery = RouteRecovery<FakeRoute> { _, gain in
            let route = FakeRoute(gain: gain); routes.append(route); return route
        }
        let saved = [chrome: AppVolume(enabled: true)]
        _ = recovery.reconcile(settings: saved, targets: [chrome: target()], playing: [], now: time)
        routes[0].responsive = false
        _ = recovery.reconcile(settings: saved, targets: [chrome: target()], playing: [], now: time)
        expectEqual(routes.count, 1)
        _ = recovery.reconcile(settings: saved, targets: [chrome: target()], playing: [chrome], now: time)
        expectEqual(routes.count, 2)
        expectTrue(routes[0].stopped)
    }

    func testUnrelatedDiscordProcessAndGainUpdateDoNotRebuildChrome() {
        var routes: [FakeRoute] = []
        let recovery = RouteRecovery<FakeRoute> { _, gain in
            let route = FakeRoute(gain: gain); routes.append(route); return route
        }
        var saved = [chrome: AppVolume(enabled: true)]
        _ = recovery.reconcile(settings: saved, targets: [chrome: target()], playing: [chrome], now: time)
        saved[chrome]?.muted = true
        let report = recovery.reconcile(settings: saved,
            targets: [chrome: target(), "com.hnc.Discord": target(processes: [99])], playing: [chrome], now: time)
        expectEqual(routes.count, 1)
        expectEqual(routes[0].gain, 0)
        expectEqual(report.active, [chrome])
    }

    func testSavedEnabledMuteRestoresAfterAppRestart() throws {
        let saved = [chrome: AppVolume(volume: 0.35, muted: true, enabled: true, name: "Chrome")]
        let data = try JSONEncoder().encode(saved)
        let restored = try JSONDecoder().decode([String: AppVolume].self, from: data)
        var gain: Float?
        let recovery = RouteRecovery<FakeRoute> { _, value in gain = value; return FakeRoute(gain: value) }
        let report = recovery.reconcile(settings: restored, targets: [chrome: target()], playing: [], now: time)
        expectEqual(report.active, [chrome])
        expectEqual(gain, 0)
        expectEqual(restored[chrome]?.volume, 0.35)
        expectEqual(restored[chrome]?.name, "Chrome")
    }

    func testLegacyMuteMigratesAndExplicitDisabledIsRespected() throws {
        let legacy = Data(#"{"volume":0.8,"muted":true}"#.utf8)
        let migrated = try JSONDecoder().decode(AppVolume.self, from: legacy)
        expectTrue(migrated.enabled)
        expectEqual(migrated.gain, 0)
        let disabled = AppVolume(volume: 0.8, muted: true, enabled: false)
        let decoded = try JSONDecoder().decode(AppVolume.self, from: JSONEncoder().encode(disabled))
        expectFalse(decoded.enabled)
        expectTrue(decoded.muted)
    }
}
