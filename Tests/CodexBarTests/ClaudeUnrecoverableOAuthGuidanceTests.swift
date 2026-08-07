import Foundation
import Testing
@testable import CodexBarCore

/// Regression coverage for #2733: a profile no refresh can restore must not be told to click Refresh.
@Suite(.serialized)
struct ClaudeUnrecoverableOAuthGuidanceTests {
    private func makeTemporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexbar-guidance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCredentialsData(expiresAt: Date) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        return Data("""
        {
          "claudeAiOauth": {
            "accessToken": "from-file",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]
          }
        }
        """.utf8)
    }

    private func backgroundPolicy() -> ClaudeUsageFetcher.ClaudeOAuthKeychainPromptPolicy {
        ClaudeUsageFetcher.ClaudeOAuthKeychainPromptPolicy(
            mode: .onlyOnUserAction,
            isApplicable: true,
            interaction: .background)
    }

    private func message(from error: Error) -> String? {
        guard case let ClaudeUsageError.oauthFailed(message) = error else { return nil }
        return message
    }

    @Test
    func `a profile no refresh can restore is told to switch source, not to click Refresh`() async throws {
        let root = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Keychain reads disabled (production always is) and no credentials file: nothing a delegated
        // refresh produces can ever be read back, so "Click Refresh" would loop forever.
        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(
                root.appendingPathComponent(".credentials.json"))
            {
                #expect(ClaudeUsageFetcher.isDelegatedRefreshProvablyUnreadable(environment: [:]))

                let thrown = #expect(throws: ClaudeUsageError.self) {
                    try ClaudeUsageFetcher.assertDelegatedRefreshAllowedInCurrentInteraction(
                        policy: self.backgroundPolicy(),
                        allowBackgroundDelegatedRefresh: false,
                        isProvablyUnreadable: true)
                }
                #expect(self.message(from: thrown!) == ClaudeUsageFetcher.unreadableCredentialsMessage)
                #expect(self.message(from: thrown!)?.contains("Click Refresh") != true)
            }
        }
    }

    @Test
    func `a recoverable profile keeps the click Refresh guidance`() async throws {
        let root = try self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentialsURL = root.appendingPathComponent(".credentials.json")
        try self.makeCredentialsData(expiresAt: Date(timeIntervalSinceNow: 3600)).write(to: credentialsURL)

        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(credentialsURL) {
                // A credentials file is present, so a delegated refresh can still hand something back.
                #expect(!ClaudeUsageFetcher.isDelegatedRefreshProvablyUnreadable(environment: [:]))

                let thrown = #expect(throws: ClaudeUsageError.self) {
                    try ClaudeUsageFetcher.assertDelegatedRefreshAllowedInCurrentInteraction(
                        policy: self.backgroundPolicy(),
                        allowBackgroundDelegatedRefresh: false,
                        isProvablyUnreadable: false)
                }
                #expect(self.message(from: thrown!)?.contains("Click Refresh") == true)
            }
        }
    }

    @Test
    func `a user initiated refresh is never blocked by the prompt policy`() throws {
        let policy = ClaudeUsageFetcher.ClaudeOAuthKeychainPromptPolicy(
            mode: .onlyOnUserAction,
            isApplicable: true,
            interaction: .userInitiated)
        // Delegation must still run for user actions: on older Claude Code the touch itself can create the
        // credentials file, which is exactly the case the terminal verdict must not pre-empt.
        try ClaudeUsageFetcher.assertDelegatedRefreshAllowedInCurrentInteraction(
            policy: policy,
            allowBackgroundDelegatedRefresh: false,
            isProvablyUnreadable: true)
    }
}
