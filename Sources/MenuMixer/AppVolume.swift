import Foundation

struct AppVolume: Codable {
    var volume: Double = 1
    var muted = false
    var enabled = false
    var name: String?
    var gain: Float { muted ? 0 : Float(volume) }

    init(volume: Double = 1, muted: Bool = false, enabled: Bool = false, name: String? = nil) {
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 1
        self.muted = muted
        self.enabled = enabled
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case volume, muted, enabled, name }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        let muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        // v0.1.0 stored no enabled flag. Restore an existing attenuation/mute
        // preference while respecting an explicit disabled flag in newer data.
        let enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? (muted || volume < 1)
        self.init(volume: volume, muted: muted, enabled: enabled,
                  name: try values.decodeIfPresent(String.self, forKey: .name))
    }
}
