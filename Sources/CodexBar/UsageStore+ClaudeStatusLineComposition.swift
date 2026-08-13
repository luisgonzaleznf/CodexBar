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

/// What a refresh should publish, and whether the fetched result is what it came from.
///
/// The source label has to travel with the snapshot rather than be assumed from the result: a discarded
/// observation republishes the previous rows, and labelling those as statusLine-sourced would have the card
/// claim an old OAuth or CLI reading came from the user's status line.
struct ClaudeComposedSnapshot {
    let snapshot: UsageSnapshot
    let usedFetchedResult: Bool
}

/// Split out of `UsageStore+Refresh.swift` to keep that file within the file-length limit.
extension UsageStore {
    /// Applies the Claude statusLine composition to a scoped result before it is stored.
    func composedSnapshot(
        _ scoped: UsageSnapshot,
        _ provider: UsageProvider,
        _ result: ProviderFetchResult,
        _ context: ProviderRefreshOutcomeContext) -> ClaudeComposedSnapshot
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
    /// Always reports a snapshot to publish, and says whether it came from the fetched observation. Returning nil
    /// stopped the refresh dead in an earlier revision: the pipeline had already accepted the statusLine result,
    /// so nothing fell through to the CLI probe. The unusable cases now republish what is already on the card and
    /// mark the result unused, so the caller keeps the label the visible rows were actually fetched under.
    ///
    /// In production these unusable cases are unreachable — an unowned feed is not planned as a source at all, so
    /// the step never runs. They are kept because the planner's inputs are sampled a moment before the fetch, and
    /// a discarded observation must not be able to change what the card claims about itself.
    static func claudeSnapshotComposingStatusLineFeed(
        current: UsageSnapshot,
        previous: UsageSnapshot?,
        sourceLabel: String?,
        accountIsStable: Bool,
        ownership: ClaudeStatusLineRowOwnership) -> ClaudeComposedSnapshot
    {
        let used = { ClaudeComposedSnapshot(snapshot: $0, usedFetchedResult: true) }
        guard self.isClaudeStatusLineSourceLabel(sourceLabel) else { return used(current) }
        // Nothing to compose with: no prior rows exist, so none can be lost. Publishing the windows alone is
        // additive rather than destructive.
        guard let previous else { return used(current) }
        let discarded = ClaudeComposedSnapshot(snapshot: previous, usedFetchedResult: false)
        // The account moved during this very fetch, so nothing here describes it: the stored rows belong to
        // whoever was signed in before, and the observation cannot say which account it counted.
        guard accountIsStable else { return discarded }

        switch ownership {
        case .owned:
            return used(current.composingOverPreviousClaudeSnapshot(previous))
        case .foreign, .unknown:
            // The observation carries no account of its own and its drop file is shared by every account on the
            // profile, so it cannot be attributed to the active one. Publishing it anyway — even stripped of
            // identity — would put another account's numbers on the card; blanking the stored rows would throw
            // away verified data on a guess. Keep what is there and let a source that knows its own account
            // re-establish ownership.
            return discarded
        }
    }

    /// Records where the published rows came from.
    ///
    /// A discarded observation republishes the previous rows, so the label has to stay with them: the card reads
    /// this to say where its numbers came from, and those numbers were not fetched by this result.
    func recordSourceLabel(
        _ sourceLabel: String?,
        provider: UsageProvider,
        composition: ClaudeComposedSnapshot)
    {
        guard composition.usedFetchedResult else { return }
        self.lastSourceLabels[provider.instanceID] = sourceLabel
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

    /// Stores a provider snapshot, recording which Claude account owns it.
    func storeSnapshot(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        sourceLabel: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.snapshots[provider.instanceID] = snapshot
        self.recordClaudeSnapshotAccount(
            provider: provider,
            sourceLabel: sourceLabel,
            environment: environment)
    }

    /// Records the account that owns a stored Claude snapshot.
    ///
    /// Only sources that carry their own identity may establish this. Recording the *active* account against a
    /// feed observation would manufacture evidence the observation does not contain: the drop file is scoped to
    /// the profile rather than the account, and its freshness window is minutes wide, so a file written by the
    /// previous account's session would be stamped as belonging to the new one and composed beneath its identity
    /// on the next refresh.
    func recordClaudeSnapshotAccount(
        provider: UsageProvider,
        sourceLabel: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        // Provider-specific by design: Claude is the only provider whose stored rows can be composed over by a
        // later identity-free source, so it is the only one that needs its owner recorded.
        guard provider == .claude, !Self.isClaudeStatusLineSourceLabel(sourceLabel) else { return }
        // An unreadable account must not erase a known one: that would drop ownership to unknown and take the
        // feed out of the plan until the next successful poll of a real source.
        guard let uuid = ClaudeAccountProfile.accountUuid(environment: environment) else { return }
        self.claudeSnapshotAccountUuid = uuid
    }

    static func isClaudeStatusLineSourceLabel(_ sourceLabel: String?) -> Bool {
        sourceLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(ClaudeUsageDataSource.statusline.sourceLabel) == .orderedSame
    }
}
