import CoreAudio
import Foundation
import MixerDSP

@available(macOS 14.4, *)
final class AudioRoute: RecoverableAudioRoute {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?
    var callbacks: UInt { dsp.map { MixerDSPCallbackCount($0) } ?? 0 }
    private var lastCallbacks: UInt = 0
    private var lastProgress = Date()

    init(processes: [AudioObjectID], output: AudioObjectID, gain: Float) throws {
        do {
            let uid = try HAL.string(output, kAudioDevicePropertyDeviceUID)
            let outputFormats = try HAL.formats(output, scope: kAudioObjectPropertyScopeOutput)
            let physicalInputs = try HAL.formats(output, scope: kAudioObjectPropertyScopeInput)
            // Explicitly reject formats/layouts the first prototype cannot route correctly.
            guard outputFormats.count == 1, let outputFormat = outputFormats.first,
                  HAL.isFloatPCM(outputFormat), (1...2).contains(outputFormat.mChannelsPerFrame) else {
                throw MixerError(message: "현재 버전은 단일 모노·스테레오 출력 스트림을 지원합니다. Mac 내장 스피커나 헤드폰으로 시도해 주세요.")
            }
            let sampleRate = outputFormat.mSampleRate
            let description = CATapDescription(processes: processes, deviceUID: uid, stream: 0)
            description.name = "Menu Mixer app volume"
            description.isPrivate = true
            // Original audio remains audible until the callback starts reading the tap.
            description.muteBehavior = .mutedWhenTapped
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "앱 오디오 연결")
            let tapFormat = try HAL.format(tap, kAudioTapPropertyFormat)
            guard HAL.isFloatPCM(tapFormat), tapFormat.mChannelsPerFrame == outputFormat.mChannelsPerFrame,
                  abs(tapFormat.mSampleRate - sampleRate) < 1 else {
                throw MixerError(message: "이 출력 기기의 오디오 형식은 아직 지원하지 않습니다.")
            }

            let configuration: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Menu Mixer private output",
                kAudioAggregateDeviceUIDKey: "local.menumixer.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                  kAudioSubTapDriftCompensationKey: true]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate), "재생 경로 만들기")
            var ready = false
            for _ in 0..<30 {
                if (try? HAL.uint(aggregate, kAudioDevicePropertyDeviceIsAlive)) == 1 {
                    let inputs = (try? HAL.formats(aggregate, scope: kAudioObjectPropertyScopeInput)) ?? []
                    let outputs = (try? HAL.formats(aggregate, scope: kAudioObjectPropertyScopeOutput)) ?? []
                    if !inputs.isEmpty && !outputs.isEmpty { ready = true; break }
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard ready else { throw MixerError(message: "오디오 기기 준비 시간이 초과되었습니다. 다시 시도해 주세요.") }
            let inputs = try HAL.formats(aggregate, scope: kAudioObjectPropertyScopeInput)
            let outputs = try HAL.formats(aggregate, scope: kAudioObjectPropertyScopeOutput)
            // Physical input streams precede tap streams. When disabled, HAL
            // retains their buffer slots with NULL data pointers.
            let tapInputs = Array(inputs.dropFirst(physicalInputs.count))
            guard (tapInputs + outputs).allSatisfy({ HAL.isFloatPCM($0) && abs($0.mSampleRate - sampleRate) < 1 }),
                  tapInputs.reduce(0, { $0 + $1.mChannelsPerFrame }) == tapFormat.mChannelsPerFrame,
                  outputs.reduce(0, { $0 + $1.mChannelsPerFrame }) == outputFormat.mChannelsPerFrame else {
                throw MixerError(message: "재생 경로의 채널 구성이 예상과 다릅니다. 원래 재생 경로로 복구했습니다.")
            }
            guard let state = MixerDSPCreate(gain) else { throw MixerError(message: "오디오 처리 메모리를 확보하지 못했습니다.") }
            dsp = state
            MixerDSPSetInputOffset(state, physicalInputs.reduce(0, { $0 + $1.mChannelsPerFrame }))
            try HAL.check(AudioDeviceCreateIOProcID(aggregate, MixerDSPGetRenderCallback(), UnsafeMutableRawPointer(state), &ioProc), "오디오 처리 준비")
            if let ioProc {
                try HAL.check(MixerDSPUseTapInputs(aggregate, ioProc, UInt32(physicalInputs.count), UInt32(inputs.count)), "마이크 입력 제외")
            }
            try HAL.check(AudioDeviceStart(aggregate, ioProc), "앱별 볼륨 조절 시작")
        } catch {
            stop()
            throw error
        }
    }

    func setGain(_ gain: Float) { if let dsp { MixerDSPSetGain(dsp, gain) } }

    func isResponsive(playing: Bool, now: Date) -> Bool {
        let count = callbacks
        if !playing || count != lastCallbacks {
            lastCallbacks = count
            lastProgress = now
            return true
        }
        return now.timeIntervalSince(lastProgress) < 6
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            self.ioProc = nil
        }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let dsp { MixerDSPDestroy(dsp); self.dsp = nil }
    }

    deinit { stop() }
}

// Core Audio creation/teardown can block; keep it off the main/UI thread.
@available(macOS 14.4, *)
actor AudioBackend {
    private var recovery = RouteRecovery<AudioRoute> { target, gain in
        try AudioRoute(processes: Array(target.processIDs), output: target.outputID, gain: gain)
    }

    func discover() throws -> AudioDiscovery { try discoverAudio() }

    func reconcile(settings: [String: AppVolume], groups: [String: Set<AudioObjectID>],
                   playing: Set<String>, output: AudioObjectID) throws -> RecoveryReport {
        let currentOutput = try HAL.uint(HAL.system, kAudioHardwarePropertyDefaultOutputDevice)
        guard currentOutput == output, output != kAudioObjectUnknown else {
            throw MixerError(message: "출력 기기 전환 중입니다. 저장된 설정으로 자동 재연결합니다.")
        }
        let inputs = try HAL.formats(output, scope: kAudioObjectPropertyScopeInput).map(AudioFormatSignature.init)
        let outputs = try HAL.formats(output, scope: kAudioObjectPropertyScopeOutput).map(AudioFormatSignature.init)
        let targets = groups.mapValues {
            RouteTarget(processIDs: $0, outputID: output, inputFormats: inputs, outputFormats: outputs)
        }
        return recovery.reconcile(settings: settings, targets: targets, playing: playing)
    }

    func gain(key: String, value: Float) { recovery.gain(key: key, value: value) }
    func stopAll() { recovery.stopAll() }
}
