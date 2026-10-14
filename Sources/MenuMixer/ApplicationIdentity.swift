import Foundation

struct ApplicationIdentity: Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    let source: String
}

struct RunningApplicationRecord {
    let pid: Int32
    let bundleID: String
    let name: String
    let enclosingApp: ApplicationIdentity?
}

enum ApplicationIdentityResolver {
    static func isSharedService(_ bundleID: String) -> Bool {
        bundleID == "com.apple.WebKit" || bundleID.hasPrefix("com.apple.WebKit.")
            || bundleID == "com.apple.SafariPlatformSupport.Helper"
    }

    static func resolve(pid: Int32, bundleID: String,
                        applications: [RunningApplicationRecord]) -> ApplicationIdentity {
        // A shared service's bundle ID identifies executable code, not its host.
        // Always select its exact PID before consulting any display metadata.
        let process = applications.first { $0.pid == pid }
        if let app = process?.enclosingApp { return app }
        let hosts = applications.filter { $0.enclosingApp?.id == $0.bundleID }

        if isSharedService(bundleID) {
            if let name = process?.name, !name.isEmpty {
                // AppKit gives each WebKit XPC process a host-prefixed name,
                // e.g. "Safari Graphics and Media". Match only a unique host;
                // never choose the first process with com.apple.WebKit.GPU.
                let matches = hosts.compactMap(\.enclosingApp).filter {
                    !$0.name.isEmpty && (name == $0.name || name.hasPrefix($0.name + " "))
                }
                if let app = uniqueLongest(matches, length: { $0.name.count }) {
                    return ApplicationIdentity(id: app.id, name: app.name,
                                               bundlePath: app.bundlePath, source: "process-host-name")
                }
            }
            return unresolved(pid: pid, bundleID: bundleID, name: process?.name)
        }

        // Chromium/Electron helpers have an app-specific bundle family, unlike
        // WebKit. Limit candidates to actual containing applications.
        let matches = hosts.compactMap(\.enclosingApp).filter {
            !$0.id.isEmpty && (bundleID == $0.id || bundleID.hasPrefix($0.id + "."))
        }
        if let app = uniqueLongest(matches, length: { $0.id.count }) {
            return ApplicationIdentity(id: app.id, name: app.name,
                                       bundlePath: app.bundlePath, source: "bundle-family")
        }
        return unresolved(pid: pid, bundleID: bundleID, name: process?.name)
    }

    private static func uniqueLongest(_ values: [ApplicationIdentity],
                                      length: (ApplicationIdentity) -> Int) -> ApplicationIdentity? {
        guard let maxLength = values.map(length).max() else { return nil }
        let matches = values.filter { length($0) == maxLength }
        let ids = Set(matches.map(\.id))
        return ids.count == 1 ? matches.first : nil
    }

    private static func unresolved(pid: Int32, bundleID: String, name: String?) -> ApplicationIdentity {
        let shared = isSharedService(bundleID)
        let id = shared || bundleID.isEmpty ? "process.\(bundleID).\(pid)" : bundleID
        let label = name.flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundleID.isEmpty ? "오디오 프로세스 \(pid)" : bundleID)
        return ApplicationIdentity(id: id, name: label, bundlePath: nil, source: "process-only")
    }
}
