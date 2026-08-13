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
        #expect(composed.snapshot.primary?.usedPercent == 77)
        #expect(composed.snapshot.secondary?.usedPercent == 88)
        #expect(composed.snapshot.updatedAt == Date(timeIntervalSince1970: 2000))

        // Everything the feed cannot know is preserved rather than blanked.
        #expect(composed.snapshot.identity?.accountEmail == "person@example.com")
        #expect(composed.snapshot.identity?.loginMethod == "Max 20x")
        #expect(composed.snapshot.tertiary?.usedPercent == 30)
        #expect(composed.snapshot.extraRateWindows?.count == 1)
        #expect(composed.snapshot.dataConfidence == .exact)
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
            #expect(result.snapshot.identity?.accountEmail == "person@example.com")
            #expect(result.snapshot.primary?.usedPercent == 10)
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
        #expect(composed.snapshot.primary?.usedPercent == 77)
        #expect(composed.snapshot.identity == nil)
    }

    @Test
    func `an account change during the fetch discards the observation`() {
        // Neither side can be trusted: the stored rows belong to whoever was signed in before, and the
        // observation cannot say which account it counted. Publishing its windows anyway would put one account's
        // numbers on the other's card.
        let result = UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.feedSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "statusline",
            accountIsStable: false,
            ownership: .owned)
        #expect(result.snapshot.primary?.usedPercent == 10)
        #expect(result.usedFetchedResult == false)
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
        #expect(result.snapshot.identity?.accountEmail == "person@example.com")
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
        // Publishing the windows even stripped of identity would show another account's numbers, because the
        // drop file is shared by every account on the profile. The card keeps what it had.
        #expect(result.snapshot.primary?.usedPercent == 10)
        #expect(result.snapshot.identity?.accountEmail == "person@example.com")
        #expect(result.usedFetchedResult == false)
    }

    @Test
    func `a discarded observation does not relabel the card as statusLine sourced`() {
        // The card renders "From your Claude statusLine config" off the recorded source label. A discarded
        // observation republishes the previous rows, so claiming this result's label would have the card
        // attribute an old OAuth or CLI reading to the user's status line.
        for ownership in [ClaudeStatusLineRowOwnership.foreign, .unknown] {
            let result = UsageStore.claudeSnapshotComposingStatusLineFeed(
                current: self.feedSnapshot(),
                previous: self.polledSnapshot(),
                sourceLabel: "statusline",
                accountIsStable: true,
                ownership: ownership)
            #expect(result.usedFetchedResult == false, "\(ownership) must not claim the fetched label")
        }
    }

    @Test
    func `a composed observation does claim its own label`() {
        let result = UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.feedSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "statusline",
            accountIsStable: true,
            ownership: .owned)
        #expect(result.usedFetchedResult)
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
        #expect(result.snapshot.identity?.accountEmail == "person@example.com")
        #expect(result.snapshot.tertiary?.usedPercent == 30)
        // Not the feed's windows: they could not be attributed, so they are not shown.
        #expect(result.snapshot.primary?.usedPercent == 10)
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
            #expect(result.snapshot.primary != nil, "stable=\(stable) ownership=\(ownership) published nothing")
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
        #expect(result.snapshot.identity?.accountEmail == "person@example.com")
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
    func `a feed observation never establishes who owns the rows it produced`() throws {
        // The observation carries no account, and its drop file is shared by every account on the profile.
        // Recording the active account against it would let a file written by the previous account's session be
        // composed beneath the new account's identity on the very next refresh.
        let environment = try self.claudeProfile(accountUuid: "account-a")
        let store = self.makeStore(suiteName: "ClaudeStatusLineComposition-sequence")

        store.storeSnapshot(
            self.feedSnapshot(),
            provider: .claude,
            sourceLabel: "statusline",
            environment: environment)

        #expect(store.claudeSnapshotAccountUuid == nil)
        #expect(store.claudeStatusLineRowOwnership(environment: environment) == .unknown)
    }

    @Test
    func `a poll that carries its own identity is what establishes ownership`() throws {
        let environment = try self.claudeProfile(accountUuid: "account-a")
        let store = self.makeStore(suiteName: "ClaudeStatusLineComposition-establish")

        for label in ["oauth", "cli", "web"] {
            let scoped = self.makeStore(suiteName: "ClaudeStatusLineComposition-establish-\(label)")
            scoped.storeSnapshot(
                self.polledSnapshot(),
                provider: .claude,
                sourceLabel: label,
                environment: environment)
            #expect(
                scoped.claudeStatusLineRowOwnership(environment: environment) == .owned,
                "\(label) must establish ownership")
        }

        store.storeSnapshot(
            self.polledSnapshot(),
            provider: .claude,
            sourceLabel: "cli",
            environment: environment)
        #expect(store.claudeStatusLineRowOwnership(environment: environment) == .owned)
    }

    @Test
    func `a switched account is recognised rather than assumed`() throws {
        let store = self.makeStore(suiteName: "ClaudeStatusLineComposition-switch")
        try store.storeSnapshot(
            self.polledSnapshot(),
            provider: .claude,
            sourceLabel: "oauth",
            environment: self.claudeProfile(accountUuid: "account-a"))

        let afterSwitch = try self.claudeProfile(accountUuid: "account-b")
        #expect(store.claudeStatusLineRowOwnership(environment: afterSwitch) == .foreign)
    }

    @Test
    func `an unreadable account does not erase an owner that was already recorded`() throws {
        // Overwriting with nil would drop ownership to unknown and take the feed out of the plan until the next
        // successful poll of a real source.
        let environment = try self.claudeProfile(accountUuid: "account-a")
        let store = self.makeStore(suiteName: "ClaudeStatusLineComposition-erase")
        store.storeSnapshot(self.polledSnapshot(), provider: .claude, sourceLabel: "oauth", environment: environment)

        try store.storeSnapshot(
            self.polledSnapshot(),
            provider: .claude,
            sourceLabel: "oauth",
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
        store.storeSnapshot(self.polledSnapshot(), provider: .claude, sourceLabel: "oauth", environment: environment)

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
        #expect(composed.snapshot.primary?.usedPercent == 66)
        // An absent window means "no update", not "cleared".
        #expect(composed.snapshot.secondary?.usedPercent == 20)
    }
}
