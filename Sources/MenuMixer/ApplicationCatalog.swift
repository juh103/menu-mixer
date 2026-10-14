import AppKit

@MainActor
struct ApplicationCatalog {
    private let records: [RunningApplicationRecord]

    init(pids: [pid_t]) {
        var byPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications { byPID[app.processIdentifier] = app }
        for pid in pids where byPID[pid] == nil {
            if let app = NSRunningApplication(processIdentifier: pid) { byPID[pid] = app }
        }
        records = byPID.values.map { app in
            let outerURL: URL? = app.executableURL.flatMap { url in
                guard let range = url.path.range(of: ".app/") else { return nil }
                return URL(fileURLWithPath: String(url.path[..<range.lowerBound]) + ".app")
            } ?? app.bundleURL.flatMap { $0.pathExtension == "app" ? $0 : nil }
            let identity: ApplicationIdentity? = outerURL.flatMap { url in
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? app.localizedName ?? url.deletingPathExtension().lastPathComponent
                return ApplicationIdentity(id: id, name: name, bundlePath: url.path, source: "containing-bundle")
            }
            return RunningApplicationRecord(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "",
                                            name: app.localizedName ?? "", enclosingApp: identity)
        }
    }

    func identity(for process: AudioProcess) -> ApplicationIdentity {
        ApplicationIdentityResolver.resolve(pid: process.pid, bundleID: process.bundleID, applications: records)
    }
}
