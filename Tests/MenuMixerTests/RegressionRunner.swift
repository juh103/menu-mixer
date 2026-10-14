import Foundation

func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}
func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value, "Expected false", file: file, line: line)
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
func expectEqual(_ actual: Float, _ expected: Float, accuracy: Float,
                 file: StaticString = #file, line: UInt = #line) {
    precondition(abs(actual - expected) <= accuracy, "Expected \(expected), got \(actual)", file: file, line: line)
}
func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value != nil, "Expected a value", file: file, line: line)
}

@main
struct RegressionRunner {
    static func main() throws {
        let tests = RouteRecoveryTests()
        let identity = IdentityTests()
        let cases: [(String, () throws -> Void)] = [
            ("Chrome mute survives Discord call entry and exit", tests.testChromeMuteSurvivesDiscordCallModeEntryAndExit),
            ("Same-rate channel changes rebuild", tests.testChannelCountChangeAtSameRateAlsoRebuilds),
            ("Different output restores volume", tests.testDifferentOutputRestoresAttenuation),
            ("New helper process restores mute", tests.testHelperDisappearsThenNewProcessReturnsWithSameMute),
            ("Failed reconnect retries", tests.testFailedReconnectionRetriesWithoutLosingPreference),
            ("New device bypasses old retry delay", tests.testNewDeviceBypassesOldDeviceRetryDelay),
            ("Explicit disable cancels recovery", tests.testExplicitDisableCancelsPendingRecovery),
            ("Idle and stalled playback", tests.testIdleDoesNotRebuildButStalledPlaybackDoes),
            ("Unrelated Discord process preserves Chrome", tests.testUnrelatedDiscordProcessAndGainUpdateDoNotRebuildChrome),
            ("App restart restores saved mute", tests.testSavedEnabledMuteRestoresAfterAppRestart),
            ("Legacy migration and explicit disable", tests.testLegacyMuteMigratesAndExplicitDisabledIsRespected),
            ("Safari/WARP sharing WebKit stay separate", identity.testSafariAndWarpSharingWebKitStaySeparate),
            ("Process order does not change ownership", identity.testRunningAppOrderDoesNotChangeAttribution),
            ("Unknown WebKit service does not guess an app", identity.testUnknownSharedServiceDoesNotGuessWarpOrSafari),
            ("Ambiguous host name stays unresolved", identity.testAmbiguousHostNameStaysUnresolved),
            ("Host name requires a word boundary", identity.testHostNameRequiresWordBoundary),
            ("Localized helper name resolves host", identity.testLocalizedHelperNameUsesTheSameHost),
            ("Containing app takes precedence", identity.testContainingApplicationWinsOverHelperDisplayName),
            ("Chrome helper bundle family", identity.testChromeHelperUsesItsOwnBundleFamily)
        ]
        for (name, run) in cases {
            try run()
            print("PASS: \(name)")
        }
        print("PASS: \(cases.count) recovery/settings regression tests")
    }
}
