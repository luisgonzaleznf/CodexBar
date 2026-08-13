import Foundation

public struct ClaudeProviderSettings: Sendable {
    public let usageDataSource: ClaudeUsageDataSource
    public let webExtrasEnabled: Bool
    /// Opt-in Claude statusLine usage feed. Off unless the user turns it on (owner ruling, #2733).
    public let statusLineFeedEnabled: Bool
    /// Whether the stored Claude rows are provably owned by the account that is active now.
    ///
    /// The statusLine payload carries no account identity and its drop file is scoped to the profile, not the
    /// account, so two accounts sharing one `CLAUDE_CONFIG_DIR` produce indistinguishable observations. The feed
    /// therefore cannot be attributed on its own: it may only supplement rows whose owner is already established.
    /// Planning the step without that proof is what forces the decision downstream, where the only remaining
    /// options are to publish something unattributed or to publish nothing and stall the chain.
    public let statusLineFeedRowsAreOwned: Bool
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?
    public let organizationID: String?

    public init(
        usageDataSource: ClaudeUsageDataSource,
        webExtrasEnabled: Bool,
        statusLineFeedEnabled: Bool = false,
        statusLineFeedRowsAreOwned: Bool = false,
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String?,
        organizationID: String? = nil)
    {
        self.usageDataSource = usageDataSource
        self.webExtrasEnabled = webExtrasEnabled
        self.statusLineFeedEnabled = statusLineFeedEnabled
        self.statusLineFeedRowsAreOwned = statusLineFeedRowsAreOwned
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.organizationID = organizationID
    }
}

public enum ClaudeProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.claude
    public typealias Section = ClaudeProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias ClaudeProviderSettings = CodexBarCore.ClaudeProviderSettings
    public var claude: ClaudeProviderSettings? {
        self[ClaudeProviderSettingsKey.self]
    }

    public static func make(claude: ClaudeProviderSettings?) -> Self {
        self.make(claude, for: ClaudeProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func claude(_ section: ClaudeProviderSettings) -> Self {
        Self(section, for: ClaudeProviderSettingsKey.self)
    }
}
