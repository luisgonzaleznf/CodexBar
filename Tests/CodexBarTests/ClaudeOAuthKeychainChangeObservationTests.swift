import Foundation
import Testing
@testable import CodexBarCore

@Suite
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

    @Test("an unreadable current reading is indeterminate, never unchanged")
    func unreadableCurrentIsIndeterminate() {
        // The regression this guards: a background probe that could not read the keychain used to be reported as
        // "did not change", which parked an account on an expired cached token until a manual refresh.
        #expect(self.classify(before: "fingerprint-a", current: nil) == .indeterminate)
    }

    @Test("an unreadable reading is distinct from an equal reading")
    func indeterminateIsNotUnchanged() {
        let unreadable = self.classify(before: "fingerprint-a", current: nil)
        let equal = self.classify(before: "fingerprint-a", current: "fingerprint-a")
        #expect(unreadable != equal)
        #expect(equal == .unchanged)
    }

    @Test("a differing reading is a change")
    func differingReadingIsChange() {
        #expect(self.classify(before: "fingerprint-a", current: "fingerprint-b") == .changed)
    }

    @Test("a missing baseline stays a change for Security.framework observation")
    func missingBaselineIsChangeWhenNotStrict() {
        // Preserves pre-existing Security.framework behavior: something readable where nothing was readable
        // before still counts as movement.
        #expect(self.classify(before: nil, current: "fingerprint-a") == .changed)
    }

    @Test("a missing baseline is inconclusive for security CLI observation")
    func missingBaselineIsIndeterminateWhenStrict() {
        #expect(
            self.classify(
                before: nil,
                current: "fingerprint-a",
                missingBaselineIsIndeterminate: true) == .indeterminate)
    }

    @Test("both readings unreadable is indeterminate rather than unchanged")
    func bothUnreadableIsIndeterminate() {
        #expect(self.classify(before: nil, current: nil) == .indeterminate)
    }
}
