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
    func `the feed supplies windows while every other row survives from the last poll`() throws {
        let composed = try #require(UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.feedSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "statusline",
            accountIsStable: true))

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
    func `a poll from any other source is published unchanged`() throws {
        let polled = self.polledSnapshot()
        for label in ["oauth", "cli", "web", "api"] {
            let result = try #require(UsageStore.claudeSnapshotComposingStatusLineFeed(
                current: polled,
                previous: self.feedSnapshot(),
                sourceLabel: label,
                accountIsStable: true))
            // Composition must not touch the polled sources' own results.
            #expect(result.identity?.accountEmail == "person@example.com")
            #expect(result.primary?.usedPercent == 10)
        }
    }

    @Test
    func `with no previous snapshot the feed publishes its windows alone`() throws {
        // Nothing exists to be replaced, so showing the windows is additive rather than destructive.
        let composed = try #require(UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.feedSnapshot(),
            previous: nil,
            sourceLabel: "statusline",
            accountIsStable: true))
        #expect(composed.primary?.usedPercent == 77)
        #expect(composed.identity == nil)
    }

    @Test
    func `an account change since the last snapshot discards the observation`() {
        // The feed carries no account identity, so it cannot be shown over another account's rows. Dropping it
        // is the only safe answer — this is the mixed-account card the siloing rule forbids.
        #expect(UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.feedSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "statusline",
            accountIsStable: false) == nil)
    }

    @Test
    func `an account change does not discard a normally polled result`() throws {
        // Only the unattributable feed is dropped; the polled sources carry their own identity.
        let result = try #require(UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: self.polledSnapshot(),
            previous: self.polledSnapshot(),
            sourceLabel: "oauth",
            accountIsStable: false))
        #expect(result.identity?.accountEmail == "person@example.com")
    }

    @Test
    func `a feed observation missing one window keeps the other from the last poll`() throws {
        let weeklyOnly = UsageSnapshot(
            primary: self.window(66, minutes: 10080),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 3000),
            identity: nil)
        let composed = try #require(UsageStore.claudeSnapshotComposingStatusLineFeed(
            current: weeklyOnly,
            previous: self.polledSnapshot(),
            sourceLabel: "statusline",
            accountIsStable: true))
        #expect(composed.primary?.usedPercent == 66)
        // An absent window means "no update", not "cleared".
        #expect(composed.secondary?.usedPercent == 20)
    }
}
