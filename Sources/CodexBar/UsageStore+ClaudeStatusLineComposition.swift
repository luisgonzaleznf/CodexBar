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
        guard let composed = Self.claudeSnapshotComposingStatusLineFeed(
            current: scoped,
            previous: self.snapshots[provider.instanceID],
            sourceLabel: provider == .claude ? result.sourceLabel : nil,
            accountIsStable: context.claudeOAuthActiveAccountObservation != .changed)
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
        accountIsStable: Bool) -> UsageSnapshot?
    {
        guard self.isClaudeStatusLineSourceLabel(sourceLabel) else { return current }
        // Nothing to compose with: no prior rows exist, so none can be lost. Publishing the windows alone is
        // additive rather than destructive.
        guard let previous else { return current }
        guard accountIsStable else { return nil }

        return current.composingOverPreviousClaudeSnapshot(previous)
    }

    static func isClaudeStatusLineSourceLabel(_ sourceLabel: String?) -> Bool {
        sourceLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(ClaudeUsageDataSource.statusline.sourceLabel) == .orderedSame
    }
}
