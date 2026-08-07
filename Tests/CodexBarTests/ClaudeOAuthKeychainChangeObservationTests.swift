import Foundation
import Testing
@testable import CodexBarCore

/// Regression coverage for #2733: an unreadable keychain must never read as "unchanged".
struct ClaudeOAuthKeychainChangeObservationTests {
    private typealias Observation = ClaudeOAuthDelegatedRefreshCoordinator.KeychainChangeObservation

    private func classify(
        before: String?,
        current: String?,
        missingBaselineIsIndeterminate: Bool = false) -> Observation
    {
        ClaudeOAuthDelegatedRefreshCoordinator.classifyObservation(
            before: before,
            current: current,
            missingBaselineIsIndeterminate: missingBaselineIsIndeterminate)
    }

    @Test
    func `an unreadable current reading is indeterminate rather than unchanged`() {
        // The regression this guards: a probe that could not read the keychain used to report "did not change",
        // which parked an account on an expired cached token until a manual refresh.
        #expect(self.classify(before: "fingerprint-a", current: nil) == .indeterminate)
    }

    @Test
    func `an unreadable reading stays distinct from an equal reading`() {
        let unreadable = self.classify(before: "fingerprint-a", current: nil)
        let equal = self.classify(before: "fingerprint-a", current: "fingerprint-a")
        #expect(unreadable != equal)
        #expect(equal == .unchanged)
    }

    @Test
    func `a differing reading is a change`() {
        #expect(self.classify(before: "fingerprint-a", current: "fingerprint-b") == .changed)
    }

    @Test
    func `a missing baseline stays a change for security framework observation`() {
        // Preserves pre-existing Security.framework behavior: something readable where nothing was readable
        // before still counts as movement.
        #expect(self.classify(before: nil, current: "fingerprint-a") == .changed)
    }

    @Test
    func `a missing baseline is inconclusive for security CLI observation`() {
        #expect(
            self.classify(
                before: nil,
                current: "fingerprint-a",
                missingBaselineIsIndeterminate: true) == .indeterminate)
    }

    @Test
    func `both readings unreadable is indeterminate rather than unchanged`() {
        #expect(self.classify(before: nil, current: nil) == .indeterminate)
    }
}
