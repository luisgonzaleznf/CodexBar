import Foundation

extension UsageSnapshot {
    /// Fills in everything a statusLine observation cannot know from the last polled Claude snapshot.
    ///
    /// The feed reports two usage windows and nothing else, so identity, plan, model-scoped weekly, Daily
    /// Routines, extra usage and cost all have to come from the polled sources or they vanish from the card.
    /// Only the windows the observation actually carries are taken from it.
    public func composingOverPreviousClaudeSnapshot(_ previous: UsageSnapshot) -> UsageSnapshot {
        UsageSnapshot(
            primary: self.primary ?? previous.primary,
            secondary: self.secondary ?? previous.secondary,
            tertiary: previous.tertiary,
            extraRateWindows: previous.extraRateWindows,
            providerCost: previous.providerCost,
            details: previous.details,
            openAIAPIUsage: previous.openAIAPIUsage,
            codexResetCredits: previous.codexResetCredits,
            mistralUsage: previous.mistralUsage,
            subscriptionExpiresAt: previous.subscriptionExpiresAt,
            subscriptionRenewsAt: previous.subscriptionRenewsAt,
            updatedAt: self.updatedAt,
            identity: previous.identity,
            dataConfidence: previous.dataConfidence)
    }
}
