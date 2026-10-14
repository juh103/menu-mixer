import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class LoginStartup: ObservableObject {
    private static let configuredKey = "MenuMixer.loginStartup.configured.v1"
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?

    var registered: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    init() {
        // Register once by default. Respect a later opt-out in System Settings;
        // opening the app must not silently re-enable a disabled login item.
        if !UserDefaults.standard.bool(forKey: Self.configuredKey) {
            setEnabled(true)
        }
    }

    static func enable() throws -> SMAppService.Status {
        let service = SMAppService.mainApp
        if service.status != .enabled && service.status != .requiresApproval {
            try service.register()
        }
        let status = service.status
        if status == .enabled || status == .requiresApproval {
            UserDefaults.standard.set(true, forKey: configuredKey)
        }
        return status
    }

    static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                _ = try Self.enable()
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
                UserDefaults.standard.set(true, forKey: Self.configuredKey)
            }
            error = nil
        } catch {
            self.error = "자동 실행 설정을 변경하지 못했습니다: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
