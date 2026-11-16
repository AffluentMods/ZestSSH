import WidgetKit
import SwiftUI

// The iPhone's and iPad's home screen widget (4.0): up to four of your Tree's
// hosts, each opening zestssh://connect?id=<id> (the app asks before it
// connects), and + for a new host, as Android's QuickConnectWidget.kt.
//
// What it shows, the app gives it (lib/services/widget_service.dart, through
// AppDelegate.swift): a host's id, name and address and nothing else, kept in
// the App Group both share. With the app lock on it is given no host at all,
// and says the app is locked.

// MARK: - Data

struct SSHConnection: Codable, Identifiable {
    let id: String
    let label: String
    let host: String
    let port: Int
}

/// What the app last gave the widget (version 1).
struct WidgetPayload: Codable {
    let v: Int
    let locked: Bool
    let hosts: [SSHConnection]
}

enum WidgetState {
    /// The app has not given the widget anything yet (it has not been opened
    /// since it was installed or updated).
    case notYet
    /// The app lock is on: no host is shown.
    case locked
    case hosts([SSHConnection])
}

enum WidgetStore {
    /// The key AppDelegate.swift writes.
    static let key = "widget_data"

    /// The App Group both share: ZEST_APP_GROUP in the Xcode project, carried
    /// to each Info.plist as ZestAppGroup.
    static var groupId: String {
        (Bundle.main.object(forInfoDictionaryKey: "ZestAppGroup") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
            ?? "group.com.affluentlabs.zestssh"
    }

    static func load() -> WidgetState {
        guard let defaults = UserDefaults(suiteName: groupId),
              let json = defaults.string(forKey: key),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(WidgetPayload.self, from: data) else {
            return .notYet
        }
        if payload.locked { return .locked }
        return .hosts(Array(payload.hosts.prefix(4)))
    }
}

// MARK: - Timeline Provider

struct QuickConnectProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickConnectEntry {
        QuickConnectEntry(date: Date(), state: .hosts([
            SSHConnection(id: "1", label: "web-01", host: "203.0.113.10", port: 22),
            SSHConnection(id: "2", label: "db-01", host: "203.0.113.20", port: 22),
        ]))
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickConnectEntry) -> Void) {
        completion(QuickConnectEntry(date: Date(), state: WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickConnectEntry>) -> Void) {
        // Nothing changes until the app gives new data, and then it reloads
        // the widget (WidgetCenter), so no refresh is asked for.
        let entry = QuickConnectEntry(date: Date(), state: WidgetStore.load())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct QuickConnectEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
}

// MARK: - Views

private let brandOrange = Color(red: 1.0, green: 0.478, blue: 0.102)

struct ConnectionRow: View {
    let connection: SSHConnection

    /// The app opens the saved host by its id (zestssh://connect?id=...),
    /// and asks before it connects.
    static func connectURL(for connection: SSHConnection) -> URL {
        var parts = URLComponents()
        parts.scheme = "zestssh"
        parts.host = "connect"
        parts.queryItems = [URLQueryItem(name: "id", value: connection.id)]
        return parts.url ?? URL(string: "zestssh://")!
    }

    var body: some View {
        Link(destination: Self.connectURL(for: connection)) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 14))
                    .foregroundColor(brandOrange)
                    .frame(width: 28, height: 28)
                    .background(brandOrange.opacity(0.15))
                    .cornerRadius(6)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: connection.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(verbatim: connection.host)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
                // Hidden where the system hides what is private (a locked
                // phone's StandBy, for one).
                .privacySensitive()

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08))
            .cornerRadius(10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Connect to \(connection.label)"))
        .accessibilityAddTraits(.isLink)
    }
}

/// A line or two in the middle of the widget, where no host is listed.
struct WidgetMessage: View {
    let title: LocalizedStringKey?
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct QuickConnectWidgetView: View {
    var entry: QuickConnectProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14))
                    .foregroundColor(brandOrange)
                    .accessibilityHidden(true)

                Text(verbatim: "ZestSSH")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                Link(destination: URL(string: "zestssh://connection/new")!) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel(Text("New host"))
            }
            .padding(.bottom, 2)

            switch entry.state {
            case .notYet:
                WidgetMessage(title: nil, text: "Open ZestSSH once to list your hosts here.")
            case .locked:
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
                WidgetMessage(title: "App lock is on", text: "Open ZestSSH to connect.")
            case .hosts(let connections) where connections.isEmpty:
                WidgetMessage(title: nil, text: "No hosts yet. Tap + to add one.")
            case .hosts(let connections):
                ForEach(connections) { connection in
                    ConnectionRow(connection: connection)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
    }
}

// MARK: - Widget Definition

private let widgetBackground = Color(red: 0.086, green: 0.086, blue: 0.086)

extension View {
    /// The widget's background: iOS 17 asks for it as the container's, iOS 15
    /// and 16 take it behind the content.
    @ViewBuilder
    func zestWidgetBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(widgetBackground, for: .widget)
        } else {
            background(widgetBackground)
        }
    }
}

struct QuickConnectWidget: Widget {
    let kind: String = "QuickConnectWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickConnectProvider()) { entry in
            QuickConnectWidgetView(entry: entry)
                .zestWidgetBackground()
        }
        .configurationDisplayName("Quick Connect")
        .description("Connect to your hosts in one tap")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Widget Bundle

@main
struct ZestSSHWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickConnectWidget()
    }
}

// MARK: - Preview

#if DEBUG
struct QuickConnectWidget_Previews: PreviewProvider {
    static var previews: some View {
        QuickConnectWidgetView(entry: QuickConnectEntry(
            date: Date(),
            state: .hosts([
                SSHConnection(id: "1", label: "web-01", host: "203.0.113.10", port: 22),
                SSHConnection(id: "2", label: "db-01", host: "203.0.113.20", port: 22),
                SSHConnection(id: "3", label: "build", host: "build.example.com", port: 2222),
            ])
        ))
        .zestWidgetBackground()
        .previewContext(WidgetPreviewContext(family: .systemMedium))
    }
}
#endif
