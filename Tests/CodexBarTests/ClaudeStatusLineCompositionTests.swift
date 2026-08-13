import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// The statusLine feed is deliberately partial. Publishing it whole would blank identity, plan, model-scoped
/// weekly, Daily Routines and extra usage — the "composes with, never replaces" half of the owner ruling (#2733).
@MainActor
struct ClaudeStatusLineCompositionTests {
    private func window(_ percent: Double, minutes: Int) -> RateWindow {
        RateWindow(usedPercent: percent, windowMinutes: minutes, resetsAt: nil, resetDescription: nil)
    }

    /// A full snapshot as the polled sources produce it.
    private func polledSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: self.window(10, minutes: 300),
            secondary: self.window(20, minutes: 10080),
            tertiary: self.window(30, minutes: 10080),
            extraRateWindows: [NamedRateWindow(
                id: "routines",
                title: "Daily Routines",
                window: self.window(5, minutes: 1440))],
            providerCost: nil,
            updatedAt: Date(timeIntervalSince1970: 1000),
            identity: ProviderIdentitySnapshot(
                providerID: UsageProvider.claude.instanceID,
                accountEmail: "person@example.com",
                accountOrganization: "Example Org",
                loginMethod: "Max 20x"),
            dataConfidence: .exact)
    }

    /// What the feed alone can produce: two windows, nothing else.
    private func feedSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: self.window(77, minutes: 300),
            secondary: self.window(88, minutes: 10080),
            updatedAt: Date(timeIntervalSince1970: 2000),
            identity: nil,
            dataConfidence: .unknown)
    }

    @Test
    func `the feed supplies windows while every other row survives from the last poll`() {
        let composed = UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.feedSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "statusline",
            accountIsStable: true,
            ownership: .owned)

        // Windows come from the live feed.
        #expect(composed.primary?.usedPercent == 77)
        #expect(composed.secondary?.usedPercent == 88)
        #expect(composed.updatedAt == Date(timeIntervalSince1970: 2000))

        // Everything the feed cannot know is preserved rather than blanked.
        #expect(composed.identity?.accountEmail == "person@example.com")
        #expect(composed.identity?.loginMethod == "Max 20x")
        #expect(composed.tertiary?.usedPercent == 30)
        #expect(composed.extraRateWindows?.count == 1)
        #expect(composed.dataConfidence == .exact)
    }

    @Test
    func `a poll from any other source is published unchanged`() {
        let polled = self.polledSnapshot()
        for label in ["oauth", "cli", "web", "api"] {
            let result = UsageStore.claudeSnapshotComposingStatusLineFeed(
                current: polled,
                previous: self.feedSnapshot(),
                sourceLabel: label,
                accountIsStable: true,
                ownership: .owned)
            // Composition must not touch the polled sources' own results.
            #expect(result.identity?.accountEmail == "person@example.com")
            #expect(result.primary?.usedPercent == 10)
        }
    }

    @Test
    func `with no previous snapshot the feed publishes its windows alone`() {
        // Nothing exists to be replaced, so showing the windows is additive rather than destructive.
        let composed = UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.feedSnapshot(),
            previous: nil,
            sourceLabel: "statusline",
            accountIsStable: true,
            ownership: .owned)
        #expect(composed.primary?.usedPercent == 77)
        #expect(composed.identity == nil)
    }

    @Test
    func `an account change since the last snapshot drops the rows it invalidates`() {
        // The feed carries no account identity, so it cannot be shown over another account's rows. It publishes
        // its windows alone instead: the stale identity goes, which is the mixed-account card the siloing rule
        // forbids, but the refresh still produces something rather than stalling the chain.
        let result = UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.feedSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "statusline",
            accountIsStable: false,
            ownership: .owned)
        #expect(result.identity == nil)
        #expect(result.tertiary == nil)
        #expect(result.primary?.usedPercent == 77)
    }

    @Test
    func `an account change does not discard a normally polled result`() {
        // Only the unattributable feed is dropped; the polled sources carry their own identity.
        let result = UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.polledSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "oauth",
            accountIsStable: false,
            ownership: .owned)
        #expect(result.identity?.accountEmail == "person@example.com")
    }

    @Test
    func `a feed cannot compose over rows produced by a different account`() {
        // accountIsStable only proves the account held still during this fetch. If the user switched accounts
        // and the first refresh afterwards is served by the feed, nothing re-read the account — so ownership of
        // the rows being composed over has to be established separately.
        let result = UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.feedSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "statusline",
            accountIsStable: true,
            ownership: .foreign)
        // The other account's identity and extra rows must not survive alongside these windows.
        #expect(result.identity == nil)
        #expect(result.extraRateWindows == nil)
        #expect(result.primary?.usedPercent == 77)
    }

    @Test
    func `an unreadable account leaves the visible card exactly as it was`() {
        // "Cannot tell" is not "belongs to someone else". Blanking verified rows on a guess would regress every
        // user whose account UUID cannot be read, so the previous snapshot is republished untouched.
        let result = UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.feedSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "statusline",
            accountIsStable: true,
            ownership: .unknown)
        #expect(result.identity?.accountEmail == "person@example.com")
        #expect(result.tertiary?.usedPercent == 30)
        // Not the feed's windows: they could not be attributed, so they are not shown.
        #expect(result.primary?.usedPercent == 10)
    }

    @Test
    func `a rejected observation never withholds a snapshot from the refresh`() {
        // The defect this replaces: composition returned nil, and because the fetch pipeline had already accepted
        // the statusLine result, nothing fell through to the CLI probe. Every rejection path must still publish.
        for (stable, ownership) in [
            (true, ClaudeStatusLineRowOwnership.foreign),
            (true, .unknown),
            (false, .owned),
            (false, .foreign),
            (false, .unknown),
        ] {
            let result = UsageStore.claudeSnapshotComposingStatusLineFeed(
                current: self.feedSnapshot(),
                previous: self.polledSnapshot(),
                sourceLabel: "statusline",
                accountIsStable: stable,
                ownership: ownership)
            #expect(result.primary != nil, "stable=\(stable) ownership=\(ownership) published nothing")
        }
    }

    @Test
    func `ownership is irrelevant to a normally polled result`() {
        let result = UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.polledSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "oauth",
            accountIsStable: true,
            ownership: .foreign)
        #expect(result.identity?.accountEmail == "person@example.com")
    }

    /// Builds a Claude profile whose config names `accountUuid`, plus the environment that points at it.
    private func claudeProfile(accountUuid: String) throws -> [String: String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = Data("""
        {
          "oauthAccount": {
            "accountUuid": "\(accountUuid)"
          }
        }
        """.utf8)
        try config.write(to: directory.appendingPathComponent(".claude.json"))
        return [ClaudeConfigPaths.configDirectoryEnvironmentKey: directory.path]
    }

    /// An environment whose Claude profile exists but names no account, so the UUID genuinely cannot be read.
    /// An empty environment would not do: it falls through to the real `~/.claude` of whoever runs the suite.
    private func unreadableClaudeProfile() throws -> [String: String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return [ClaudeConfigPaths.configDirectoryEnvironmentKey: directory.path]
    }

    private func makeStore(suiteName: String) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: testSettingsStore(suiteName: suiteName),
            startupBehavior: .testing)
    }

    @Test
    func `a second feed refresh still composes after the first published feed only rows`() throws {
        // The sequence that wedged the card: refresh one has no previous snapshot, so it publishes feed-only
        // rows. If storing those rows records no owner, refresh two cannot attribute them — and because the
        // pipeline had already accepted the statusLine result, the CLI probe never ran to break the tie.
        let environment = try self.claudeProfile(accountUuid: "account-a")
        let store = self.makeStore(suiteName: "ClaudeStatusLineComposition-sequence")

        store.storeSnapshot(self.feedSnapshot(), provider: .claude, environment: environment)

        #expect(store.claudeSnapshotAccountUuid == "account-a")
        #expect(store.claudeStatusLineRowOwnership(environment: environment) == .owned)
    }

    @Test
    func `a switched account is recognised rather than assumed`() throws {
        let store = self.makeStore(suiteName: "ClaudeStatusLineComposition-switch")
        try store.storeSnapshot(
            self.polledSnapshot(),
            provider: .claude,
            environment: self.claudeProfile(accountUuid: "account-a"))

        let afterSwitch = try self.claudeProfile(accountUuid: "account-b")
        #expect(store.claudeStatusLineRowOwnership(environment: afterSwitch) == .foreign)
    }

    @Test
    func `an unreadable account does not erase an owner that was already recorded`() throws {
        // Overwriting with nil would turn `.owned` into `.unknown` and freeze the card on the next feed refresh.
        let environment = try self.claudeProfile(accountUuid: "account-a")
        let store = self.makeStore(suiteName: "ClaudeStatusLineComposition-erase")
        store.storeSnapshot(self.polledSnapshot(), provider: .claude, environment: environment)

        try store.storeSnapshot(
            self.feedSnapshot(),
            provider: .claude,
            environment: self.unreadableClaudeProfile())

        #expect(store.claudeSnapshotAccountUuid == "account-a")
        #expect(store.claudeStatusLineRowOwnership(environment: environment) == .owned)
    }

    @Test
    func `a recorded owner outlives the process that recorded it`() throws {
        // Snapshots are restored across launches; an in-memory-only owner would read as unknown against them.
        let environment = try self.claudeProfile(accountUuid: "account-a")
        let settings = testSettingsStore(suiteName: "ClaudeStatusLineComposition-relaunch")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store.storeSnapshot(self.polledSnapshot(), provider: .claude, environment: environment)

        // A second store over the same defaults stands in for the next launch.
        let relaunched = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        #expect(relaunched.claudeSnapshotAccountUuid == "account-a")
        #expect(relaunched.claudeStatusLineRowOwnership(environment: environment) == .owned)
    }

    @Test
    func `a feed observation missing one window keeps the other from the last poll`() {
        let weeklyOnly = UsageSnapshot(
            primary: self.window(66, minutes: 10080),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 3000),
            identity: nil)
        let composed = UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: weeklyOnly,
            previous: self.polledSnapshot(),
            sourceLabel: "statusline",
            accountIsStable: true,
            ownership: .owned)
        #expect(composed.primary?.usedPercent == 66)
        // An absent window means "no update", not "cleared".
        #expect(composed.secondary?.usedPercent == 20)
    }
}
