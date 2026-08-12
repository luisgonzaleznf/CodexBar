import CodexBarCore
import Foundation

/// Split out of `UsageStore+Refresh.swift` to keep that file within the file-length limit.
extension UsageStore {
    /// Applies the Claude statusLine composition to a scoped result before it is stored.
    ///
    /// Returns nil when the result must not be published at all.
    func composedSnapshot(
        _ scoped: UsageSnapshot,
        _ provider: UsageProvider,
        _ result: ProviderFetchResult,
        _ context: ProviderRefreshOutcomeContext) -> UsageSnapshot?
    {
        // Provider-specific by design: the statusLine feed is a Claude-only source, so every other provider
        // must reach the composition helper with no source label and pass straight through it.
        let claudeSourceLabel = provider == .claude ? result.sourceLabel : nil
        guard let composed = Self.claudeSnapshotComposingStatusLineFeed(
            current: scoped,
            previous: self.snapshots[provider.instanceID],
            sourceLabel: claudeSourceLabel,
            accountIsStable: context.claudeOAuthActiveAccountObservation != .changed,
            ownsPreviousRows: self.claudeStatusLineOwnsPreviousRows())
        else { return nil }
        return composed
    }

    /// Composes a statusLine observation with the last polled Claude snapshot instead of publishing it whole.
    ///
    /// The feed carries only the 5h/7d windows — no identity, plan, model-scoped weekly, Daily Routines or extra
    /// usage — so publishing it as-is would blank every one of those rows. The owner ruling for this source is
    /// that it composes with the polled sources and never replaces them, which is what this restores.
    ///
    /// Returns nil when the result must not be published at all: an observation cannot be shown over a snapshot
    /// belonging to a different account, and the feed has no account identity of its own to check against, so an
    /// account change since the previous snapshot is treated as disqualifying rather than merged optimistically.
    static func claudeSnapshotComposingStatusLineFeed(
        current: UsageSnapshot,
        previous: UsageSnapshot?,
        sourceLabel: String?,
        accountIsStable: Bool,
        ownsPreviousRows: Bool) -> UsageSnapshot?
    {
        guard self.isClaudeStatusLineSourceLabel(sourceLabel) else { return current }
        // Nothing to compose with: no prior rows exist, so none can be lost. Publishing the windows alone is
        // additive rather than destructive.
        guard let previous else { return current }
        guard accountIsStable, ownsPreviousRows else { return nil }

        return current.composingOverPreviousClaudeSnapshot(previous)
    }

    /// True when the account that produced the stored Claude rows is still the active one.
    ///
    /// `claudeOAuthActiveAccountObservation` only proves the account held still during *this* fetch. If the user
    /// switched accounts and the first refresh afterwards is served by the statusLine file, nothing in that fetch
    /// re-read the account, so stability alone would let the new account's windows sit under the old account's
    /// identity. An unknown account on either side is treated as not-owned rather than assumed equal.
    func claudeStatusLineOwnsPreviousRows(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        guard let recorded = self.claudeSnapshotAccountUuid,
              let active = ClaudeAccountProfile.accountUuid(environment: environment)
        else { return false }
        return recorded == active
    }

    /// Stores a provider snapshot, recording which Claude account produced it.
    func storeSnapshot(_ snapshot: UsageSnapshot, provider: UsageProvider, sourceLabel: String?) {
        self.snapshots[provider.instanceID] = snapshot
        self.recordClaudeSnapshotAccount(provider: provider, sourceLabel: sourceLabel)
    }

    /// Records the account behind a stored Claude snapshot. The feed carries no identity, so a snapshot it
    /// produced must not become the ownership evidence for the next one.
    func recordClaudeSnapshotAccount(provider: UsageProvider, sourceLabel: String?) {
        // Provider-specific by design: only Claude has a statusLine feed whose identity-free snapshots must be
        // excluded from becoming the ownership evidence for the next composition.
        guard provider == .claude, !Self.isClaudeStatusLineSourceLabel(sourceLabel) else { return }
        self.claudeSnapshotAccountUuid = ClaudeAccountProfile.accountUuid(
            environment: ProcessInfo.processInfo.environment)
    }

    static func isClaudeStatusLineSourceLabel(_ sourceLabel: String?) -> Bool {
        sourceLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(ClaudeUsageDataSource.statusline.sourceLabel) == .orderedSame
    }
}
