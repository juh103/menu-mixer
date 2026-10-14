import Foundation

struct IdentityTests {
    private let safari = ApplicationIdentity(id: "com.apple.Safari", name: "Safari",
        bundlePath: "/Applications/Safari.app", source: "containing-bundle")
    private let warp = ApplicationIdentity(id: "com.cloudflare.1dot1dot1dot1.macos", name: "Cloudflare WARP",
        bundlePath: "/Applications/Cloudflare WARP.app", source: "containing-bundle")

    private var records: [RunningApplicationRecord] {
        [RunningApplicationRecord(pid: 10, bundleID: warp.id, name: warp.name, enclosingApp: warp),
         RunningApplicationRecord(pid: 11, bundleID: "com.apple.WebKit.GPU", name: "Cloudflare WARP Graphics and Media", enclosingApp: nil),
         RunningApplicationRecord(pid: 20, bundleID: safari.id, name: safari.name, enclosingApp: safari),
         RunningApplicationRecord(pid: 21, bundleID: "com.apple.WebKit.GPU", name: "Safari Graphics and Media", enclosingApp: nil)]
    }

    func testSafariAndWarpSharingWebKitStaySeparate() {
        let resolvedSafari = ApplicationIdentityResolver.resolve(pid: 21, bundleID: "com.apple.WebKit.GPU", applications: records)
        let resolvedWarp = ApplicationIdentityResolver.resolve(pid: 11, bundleID: "com.apple.WebKit.GPU", applications: records)
        expectEqual(resolvedSafari.id, safari.id)
        expectEqual(resolvedSafari.name, "Safari")
        expectEqual(resolvedSafari.bundlePath, safari.bundlePath)
        expectEqual(resolvedWarp.id, warp.id)
        expectEqual(resolvedWarp.name, "Cloudflare WARP")
        expectEqual(resolvedWarp.bundlePath, warp.bundlePath)
        expectFalse(resolvedSafari.id == resolvedWarp.id)
    }

    func testRunningAppOrderDoesNotChangeAttribution() {
        for list in [records, records.reversed().map { $0 }] {
            let result = ApplicationIdentityResolver.resolve(pid: 21, bundleID: "com.apple.WebKit.GPU", applications: list)
            expectEqual(result.id, safari.id)
        }
    }

    func testUnknownSharedServiceDoesNotGuessWarpOrSafari() {
        let result = ApplicationIdentityResolver.resolve(pid: 99, bundleID: "com.apple.WebKit.GPU", applications: records)
        expectFalse(result.id == safari.id)
        expectFalse(result.id == warp.id)
        expectEqual(result.source, "process-only")
        let other = ApplicationIdentityResolver.resolve(pid: 98, bundleID: "com.apple.WebKit.GPU", applications: records)
        expectFalse(result.id == other.id)
    }

    func testAmbiguousHostNameStaysUnresolved() {
        let duplicate = ApplicationIdentity(id: "com.example.other-safari", name: "Safari",
            bundlePath: "/Applications/Other Safari.app", source: "containing-bundle")
        let list = records + [RunningApplicationRecord(pid: 30, bundleID: duplicate.id, name: duplicate.name, enclosingApp: duplicate)]
        let result = ApplicationIdentityResolver.resolve(pid: 21, bundleID: "com.apple.WebKit.GPU", applications: list)
        expectEqual(result.source, "process-only")
    }

    func testHostNameRequiresWordBoundary() {
        let list = records + [RunningApplicationRecord(pid: 31, bundleID: "com.apple.WebKit.GPU", name: "SafariFake Graphics and Media", enclosingApp: nil)]
        let result = ApplicationIdentityResolver.resolve(pid: 31, bundleID: "com.apple.WebKit.GPU", applications: list)
        expectEqual(result.source, "process-only")
    }

    func testLocalizedHelperNameUsesTheSameHost() {
        let list = records + [RunningApplicationRecord(pid: 32, bundleID: "com.apple.WebKit.WebContent", name: "Safari 웹 콘텐츠", enclosingApp: nil)]
        let result = ApplicationIdentityResolver.resolve(pid: 32, bundleID: "com.apple.WebKit.WebContent", applications: list)
        expectEqual(result.id, safari.id)
    }

    func testContainingApplicationWinsOverHelperDisplayName() {
        let list = records + [RunningApplicationRecord(pid: 33, bundleID: "com.example.helper", name: "Cloudflare WARP", enclosingApp: safari)]
        let result = ApplicationIdentityResolver.resolve(pid: 33, bundleID: "com.example.helper", applications: list)
        expectEqual(result.id, safari.id)
    }

    func testChromeHelperUsesItsOwnBundleFamily() {
        let chrome = ApplicationIdentity(id: "com.google.Chrome", name: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", source: "containing-bundle")
        let list = records + [RunningApplicationRecord(pid: 40, bundleID: chrome.id, name: chrome.name, enclosingApp: chrome)]
        let result = ApplicationIdentityResolver.resolve(pid: 41, bundleID: "com.google.Chrome.helper", applications: list)
        expectEqual(result.id, chrome.id)
        expectEqual(result.bundlePath, chrome.bundlePath)
    }
}
