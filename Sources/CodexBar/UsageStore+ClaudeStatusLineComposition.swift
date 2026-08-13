import CodexBarCore
import Foundation

/// Which account owns the Claude rows a statusLine observation would be composed over.
///
/// Three states rather than two: "cannot tell" has to act differently from "belongs to someone else", because
/// only one of them justifies discarding rows the user can currently see.
enum ClaudeStatusLineRowOwnership {
    case owned
    case foreign
    case unknown
}

/// Split out of `UsageStore+Refresh.swift` to keep that file within the file-length limit.
extension UsageStore {
    /// Applies the Claude statusLine composition to a scoped result before it is stored.
    func composedSnapshot(
        _ scoped: UsageSnapshot,
        _ provider: UsageProvider,
        _ result: ProviderFetchResult,
        _ context: ProviderRefreshOutcomeContext) -> UsageSnapshot
    {
        // Provider-specific by design: the statusLine feed is a Claude-only source, so every other provider
        // must reach the composition helper with no source label and pass straight through it.
        let claudeSourceLabel = provider == .claude ? result.sourceLabel : nil
        return Self.claudeSnapshotComposingStatusLineFeed(
            current: scoped,
            previous: self.snapshots[provider.instanceID],
            sourceLabel: claudeSourceLabel,
            accountIsStable: context.claudeOAuthActiveAccountObservation != .changed,
            ownership: self.claudeStatusLineRowOwnership())
    }

    /// Composes a statusLine observation with the last polled Claude snapshot instead of publishing it whole.
    ///
    /// The feed carries only the 5h/7d windows — no identity, plan, model-scoped weekly, Daily Routines or extra
    /// usage — so publishing it as-is would blank every one of those rows. The owner ruling for this source is
    /// that it composes with the polled sources and never replaces them, which is what this restores.
    ///
    /// Always returns a snapshot to publish. An earlier revision returned nil when the observation could not be
    /// attributed, which stopped the refresh dead: the fetch pipeline had already accepted the statusLine result,
    /// so nothing fell through to the CLI probe and the card kept whatever it was last showing. Rejection now
    /// chooses between the rows it can still trust rather than between publishing and not publishing.
    static func claudeSnapshotComposingStatusLineFeed(
        current: UsageSnapshot,
        previous: UsageSnapshot?,
        sourceLabel: String?,
        accountIsStable: Bool,
        ownership: ClaudeStatusLineRowOwnership) -> UsageSnapshot
    {
        guard self.isClaudeStatusLineSourceLabel(sourceLabel) else { return current }
        // Nothing to compose with: no prior rows exist, so none can be lost. Publishing the windows alone is
        // additive rather than destructive.
        guard let previous else { return current }
        // The account moved during this very fetch, so the stored rows describe whoever was signed in before.
        guard accountIsStable else { return current }

        switch ownership {
        case .owned:
            return current.composingOverPreviousClaudeSnapshot(previous)
        case .foreign:
            // A different account owns the stored rows. Publishing the windows alone drops the identity, plan and
            // extra rows with it, which is the point: carrying them over is exactly the mislabelling to avoid.
            return current
        case .unknown:
            // Not knowing is not the same as knowing they are foreign. Blanking verified rows on a guess would be
            // a visible regression for anyone whose account UUID cannot be read, so leave the card as it stands
            // and let the next poll of a real source decide.
            return previous
        }
    }

    /// Whether the account that produced the stored Claude rows is still the active one.
    ///
    /// `claudeOAuthActiveAccountObservation` only proves the account held still during *this* fetch. If the user
    /// switched accounts and the first refresh afterwards is served by the statusLine file, nothing in that fetch
    /// re-read the account, so stability alone would let the new account's windows sit under the old account's
    /// identity.
    func claudeStatusLineRowOwnership(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeStatusLineRowOwnership
    {
        guard let recorded = self.claudeSnapshotAccountUuid,
              let active = ClaudeAccountProfile.accountUuid(environment: environment)
        else { return .unknown }
        return recorded == active ? .owned : .foreign
    }

    /// Stores a provider snapshot, recording which Claude account produced it.
    func storeSnapshot(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.snapshots[provider.instanceID] = snapshot
        self.recordClaudeSnapshotAccount(provider: provider, environment: environment)
    }

    /// Records the account that was active when a Claude snapshot was stored.
    ///
    /// This covers feed-sourced snapshots too. The feed carries no identity of its own, but the account UUID here
    /// is read from the environment rather than from the observation, so it is evidence about the moment the rows
    /// were stored — which is exactly what the next composition needs to ask about.
    func recordClaudeSnapshotAccount(
        provider: UsageProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        // Provider-specific by design: Claude is the only provider whose stored rows can be composed over by a
        // later identity-free source, so it is the only one that needs its owner recorded.
        guard provider == .claude else { return }
        // An unreadable account must not erase a known one: that would turn `.owned` into `.unknown` and freeze
        // the card until the next successful poll of a real source.
        guard let uuid = ClaudeAccountProfile.accountUuid(environment: environment) else { return }
        self.claudeSnapshotAccountUuid = uuid
    }

    static func isClaudeStatusLineSourceLabel(_ sourceLabel: String?) -> Bool {
        sourceLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(ClaudeUsageDataSource.statusline.sourceLabel) == .orderedSame
    }
}
