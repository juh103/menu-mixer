import AppKit
import SwiftUI
import CoreAudio

struct MixerApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var processes: [AudioObjectID]
    var playing: Bool
    var hasOutput: Bool = false
}

@available(macOS 14.4, *)
@MainActor
final class MixerModel: ObservableObject {
    @Published var apps: [MixerApp] = []
    @Published var active: Set<String> = []
    @Published var preferences: [String: AppVolume] = [:]
    @Published var outputName = "출력 기기 확인 중…"
    @Published var message: String?
    @Published var busy = false
    private let backend = AudioBackend()
    private var monitor: Task<Void, Never>?
    private let storageKey = "MenuMixer.appVolumes.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: AppVolume].self, from: data) {
            preferences = saved
        }
        // Older versions merged different hosts under a shared WebKit ID.
        // That preference cannot safely be assigned to either Safari or WARP.
        for id in Array(preferences.keys) where ApplicationIdentityResolver.isSharedService(id) {
            preferences[id]?.enabled = false
        }
        persist()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func settings(_ id: String) -> AppVolume { preferences[id] ?? AppVolume() }

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let discovery = try await backend.discover()
            let catalog = ApplicationCatalog(pids: discovery.processes.map(\.pid))
            var groups: [String: MixerApp] = [:]
            for process in discovery.processes {
                let identity = catalog.identity(for: process)
                let id = identity.id
                let icon = identity.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
                var group = groups[id] ?? MixerApp(id: id, name: identity.name,
                                                   icon: icon, processes: [], playing: false)
                group.processes.append(process.objectID)
                group.playing = group.playing || process.playing
                group.hasOutput = group.hasOutput || process.hasOutput
                groups[id] = group
            }
            groups = groups.filter { $0.value.hasOutput || settings($0.key).enabled }
            // Keep an enabled app visible through a brief process/device gap, so
            // the user can still edit its remembered settings or turn it off.
            for (id, value) in preferences where value.enabled && groups[id] == nil {
                let previous = apps.first { $0.id == id }
                groups[id] = MixerApp(id: id, name: value.name ?? previous?.name ?? id,
                                      icon: previous?.icon, processes: [], playing: false)
            }
            let report = try await backend.reconcile(settings: preferences,
                groups: groups.mapValues { Set($0.processes) },
                playing: Set(groups.values.filter(\.playing).map(\.id)), output: discovery.outputID)
            active = report.active
            if let id = report.errors.keys.sorted().first, let error = report.errors[id] {
                message = "\(groups[id]?.name ?? id): \(error) 설정을 유지하고 자동 재연결을 시도합니다."
            } else {
                message = nil
            }
            outputName = discovery.outputName
            apps = groups.values.sorted {
                if $0.playing != $1.playing { return $0.playing }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            await backend.stopAll()
            active.removeAll()
            apps = apps.filter { settings($0.id).enabled }.map {
                var app = $0
                app.processes = []
                app.playing = false
                return app
            }
            outputName = "출력 기기 확인 필요"
            message = error.localizedDescription
        }
    }

    func toggle(_ app: MixerApp, enabled: Bool) {
        guard !busy else { return }
        var value = settings(app.id)
        value.enabled = enabled
        value.name = app.name
        preferences[app.id] = value
        persist()
        Task { await refresh() }
    }

    func setVolume(_ id: String, _ volume: Double) {
        var value = settings(id)
        value.volume = min(1, max(0, volume))
        save(id, value)
    }

    func toggleMute(_ id: String) {
        var value = settings(id)
        value.muted.toggle()
        save(id, value)
    }

    private func save(_ id: String, _ value: AppVolume) {
        preferences[id] = value
        persist()
        Task { await backend.gain(key: id, value: value.gain) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    func releaseAll() {
        guard !busy else { return }
        for id in Array(preferences.keys) { preferences[id]?.enabled = false }
        persist()
        busy = true
        Task {
            await backend.stopAll()
            active.removeAll()
            busy = false
            message = nil
        }
    }

    func quit() {
        busy = true
        monitor?.cancel()
        Task {
            await backend.stopAll()
            NSApplication.shared.terminate(nil)
        }
    }
}
