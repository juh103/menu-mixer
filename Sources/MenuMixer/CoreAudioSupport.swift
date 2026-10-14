import AppKit
import CoreAudio

struct MixerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw MixerError(message: "\(operation)에 실패했습니다 (\(status)). 시스템 설정 → 개인정보 보호 및 보안에서 시스템 오디오 녹음 권한을 확인해 주세요.")
        }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var property = address(selector)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "오디오 상태 읽기")
        return value
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "오디오 목록 읽기")
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let capacity = size
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "오디오 목록 읽기")
        guard size <= capacity else { throw MixerError(message: "오디오 목록이 변경되었습니다. 다시 시도해 주세요.") }
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
        }
        try check(status, "오디오 이름 읽기")
        return value as String
    }

    static func format(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
        var property = address(selector)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "오디오 형식 읽기")
        return value
    }

    static func formats(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamBasicDescription] {
        try objects(device, kAudioDevicePropertyStreams, scope: scope).map {
            try format($0, kAudioStreamPropertyVirtualFormat)
        }
    }

    static func isFloatPCM(_ f: AudioStreamBasicDescription) -> Bool {
        let channelsPerBuffer: UInt32 = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : f.mChannelsPerFrame
        return f.mFormatID == kAudioFormatLinearPCM && f.mBitsPerChannel == 32
            && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && f.mBytesPerFrame == 4 * channelsPerBuffer && f.mSampleRate > 0
    }
}

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let playing: Bool
    let hasOutput: Bool
}

struct AudioDiscovery {
    let outputID: AudioObjectID
    let outputName: String
    let processes: [AudioProcess]
}

func discoverAudio() throws -> AudioDiscovery {
    let output = try HAL.uint(HAL.system, kAudioHardwarePropertyDefaultOutputDevice)
    guard output != kAudioObjectUnknown else { throw MixerError(message: "사용 가능한 출력 기기가 없습니다.") }
    let processes = try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList).compactMap { id -> AudioProcess? in
        guard let rawPID = try? HAL.uint(id, kAudioProcessPropertyPID), rawPID != UInt32(ProcessInfo.processInfo.processIdentifier) else { return nil }
        let bundleID = (try? HAL.string(id, kAudioProcessPropertyBundleID)) ?? ""
        guard bundleID != Bundle.main.bundleIdentifier else { return nil }
        let playing = (try? HAL.uint(id, kAudioProcessPropertyIsRunningOutput)) == 1
        let outputs = (try? HAL.objects(id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)) ?? []
        return AudioProcess(objectID: id, pid: pid_t(bitPattern: rawPID),
                            bundleID: bundleID,
                            playing: playing, hasOutput: playing || !outputs.isEmpty)
    }
    return AudioDiscovery(outputID: output, outputName: try HAL.string(output, kAudioObjectPropertyName), processes: processes)
}
