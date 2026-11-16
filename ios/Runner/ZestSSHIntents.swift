import AppIntents
import Foundation
import UIKit

// The Shortcuts actions and Siri phrases (iOS 16 and later; the app runs from
// iOS 15, where they are simply not offered). Each opens a zestssh:// link,
// which the app asks about before it does anything. Their words are in the
// app's twelve languages: Localizable.strings (titles, descriptions, what a
// run returns) and AppShortcuts.strings (the Siri phrases), in Runner's
// <language>.lproj folders.

// MARK: - SSH Execute Command Intent

/// Shortcuts intent: execute an SSH command on a saved connection.
@available(iOS 16.0, *)
struct ExecuteSSHCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run SSH Command"
    static var description: IntentDescription = IntentDescription(
        "Runs a command on a saved host in ZestSSH.",
        categoryName: "SSH"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Host", description: "The name of a saved host, or its id")
    var connectionName: String

    @Parameter(title: "Command", description: "The shell command to execute")
    var command: String

    @Parameter(title: "Timeout (seconds)", default: 30,
               controlStyle: .stepper, inclusiveRange: (5, 300))
    var timeout: Int

    /// The automation API key the app checks every request against (made
    /// under Automation, API keys). The action sent none, so the app refused
    /// every command it was asked to run (found 22 October 2026 while the 3.0
    /// docs were checked). It goes in the link as `key`, as an automation link's
    /// does: the app still asks "Run this from a link?" first, then checks
    /// the key, its scope and "Allow unattended runs" as for any request.
    @Parameter(title: "API Key", description: "An automation API key from ZestSSH (Automation, API keys)")
    var apiKey: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let encoded = buildURL() else {
            return .result(value: String(localized: "Error: failed to build automation URL"))
        }

        // The link carries everything: nothing is left in the shared
        // defaults (the app clears what an older version left there unread,
        // and a key must not lie there).
        await openURL(encoded)
        return .result(value: String(localized: "Command sent to ZestSSH"))
    }

    private func buildURL() -> URL? {
        var components = URLComponents()
        components.scheme = "zestssh"
        components.host = "execute"
        components.queryItems = [
            URLQueryItem(name: "connection", value: connectionName),
            URLQueryItem(name: "command", value: command),
            URLQueryItem(name: "timeout", value: String(timeout)),
            URLQueryItem(name: "key", value: apiKey),
        ]
        // A "+" is left as it is in a query, and the app reads it as a
        // space (a command such as `date +%s` arrived as `date  %s`).
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    @MainActor
    private func openURL(_ url: URL) async {
        await UIApplication.shared.open(url)
    }
}

// MARK: - SSH Run Snippet Intent

/// Shortcuts intent: run a saved snippet on a connection.
@available(iOS 16.0, *)
struct RunSSHSnippetIntent: AppIntent {
    static var title: LocalizedStringResource = "Run SSH Snippet"
    static var description: IntentDescription = IntentDescription(
        "Runs a saved snippet on a host in ZestSSH.",
        categoryName: "SSH"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Host", description: "The name of a saved host, or its id")
    var connectionName: String

    @Parameter(title: "Snippet Name", description: "The name of the saved snippet to run")
    var snippetName: String

    /// The automation API key, as for Run SSH Command (it sent none, and
    /// every snippet was refused).
    @Parameter(title: "API Key", description: "An automation API key from ZestSSH (Automation, API keys)")
    var apiKey: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let encoded = buildURL() else {
            return .result(value: String(localized: "Error: failed to build automation URL"))
        }

        await openURL(encoded)
        return .result(value: String(localized: "Snippet sent to ZestSSH"))
    }

    private func buildURL() -> URL? {
        var components = URLComponents()
        components.scheme = "zestssh"
        components.host = "snippet"
        components.queryItems = [
            URLQueryItem(name: "connection", value: connectionName),
            URLQueryItem(name: "name", value: snippetName),
            URLQueryItem(name: "key", value: apiKey),
        ]
        // A "+" is left as it is in a query, and the app reads it as a
        // space (a command such as `date +%s` arrived as `date  %s`).
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    @MainActor
    private func openURL(_ url: URL) async {
        await UIApplication.shared.open(url)
    }
}

// MARK: - SSH Connect Intent

/// Shortcuts intent: open ZestSSH and connect to a saved session.
@available(iOS 16.0, *)
struct ConnectSSHIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect via SSH"
    static var description: IntentDescription = IntentDescription(
        "Opens ZestSSH and connects to a saved host.",
        categoryName: "SSH"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Host", description: "The name of a saved host, or its id")
    var connectionName: String

    func perform() async throws -> some IntentResult {
        // The app finds the saved host by this name (or id), and asks before
        // it connects. Encoded, so a name with spaces opens too.
        var parts = URLComponents()
        parts.scheme = "zestssh"
        parts.host = "connect"
        parts.queryItems = [URLQueryItem(name: "name", value: connectionName)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else {
            return .result()
        }
        await openURL(url)
        return .result()
    }

    @MainActor
    private func openURL(_ url: URL) async {
        await UIApplication.shared.open(url)
    }
}

// MARK: - App Shortcuts Provider

/// Registers ZestSSH intents with the Shortcuts app.
@available(iOS 16.0, *)
struct ZestSSHShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ExecuteSSHCommandIntent(),
            phrases: [
                "Run SSH command with \(.applicationName)",
                "Execute command on server with \(.applicationName)",
                "Run command with \(.applicationName)",
            ],
            shortTitle: "Run SSH Command",
            systemImageName: "terminal"
        )
        AppShortcut(
            intent: RunSSHSnippetIntent(),
            phrases: [
                "Run SSH snippet with \(.applicationName)",
                "Execute snippet with \(.applicationName)",
            ],
            shortTitle: "Run Snippet",
            systemImageName: "text.badge.star"
        )
        AppShortcut(
            intent: ConnectSSHIntent(),
            phrases: [
                "Connect to server with \(.applicationName)",
                "SSH connect with \(.applicationName)",
                "Open SSH connection with \(.applicationName)",
            ],
            shortTitle: "Connect via SSH",
            systemImageName: "link"
        )
    }
}
