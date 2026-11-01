import HermesKit
import SwiftUI

/// The session list's search results: the profile's chats whose messages, title or id
/// match, as the dashboard finds them (`GatewayConnection.searchSessions`), the best match
/// first. On the Mac they take the list's place while the sidebar's search field has
/// text; on iOS they are the Search tab's page. A row opens its chat as the list's row
/// does (its Bot Chat as the Bot Chat).
struct SessionSearchResultsList: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    /// What is typed in the search field, untrimmed.
    let text: String
    /// Shows the chat a row opened (on iPhone, pushes it).
    var showChat: () -> Void = {}

    var body: some View {
        List(selection: $selection) {
            if let server = model.sessionsServer {
                content(server.connection, server: server.id)
                    .themedRows()
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
        .overlay { placeholder }
        // The debounce: a search per pause in typing, not per key (Desktop waits 200 ms).
        .task(id: searchKey) {
            guard let connection = model.sessionsServer?.connection else { return }
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await connection.searchSessions(query)
        }
        .accessibilityIdentifier("sessionSearchResults")
    }

    @ViewBuilder private func content(_ connection: GatewayConnection, server: UUID) -> some View {
        let search = connection.search
        if !search.results.isEmpty {
            Section {
                ForEach(search.results) { result in
                    let item = item(for: result, server: server)
                    SessionSearchRow(result: result)
                        .sidebarRowHighlight(isSelected: selection == item)
                        .tag(item)
                }
            } header: {
                SidebarSectionTitle(search.results.count == 1 ? "1 chat" : "\(search.results.count) chats")
            }
        }
    }

    /// No results, a failure, or a search still on its way, over the empty list.
    @ViewBuilder private var placeholder: some View {
        if let connection = model.sessionsServer?.connection {
            let search = connection.search
            if !search.isAvailable {
                ContentUnavailableView("Search Unavailable", systemImage: "magnifyingglass",
                                       description: Text("This server's sign-in can't read the dashboard."))
            } else if let error = search.error, search.query == query {
                ContentUnavailableView {
                    Label("Search Failed", systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await connection.searchSessions(query) } }
                }
            } else if query.isEmpty {
                ContentUnavailableView("Search Chats", systemImage: "magnifyingglass",
                                       description: Text("Find a chat by what was said in it, its title or its id."))
            } else if search.results.isEmpty {
                if search.isSearching || search.query != query {
                    ProgressView()
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    /// The Bot Chat's own item for its hit, so it opens as the Bot Chat; else the row's.
    private func item(for result: SessionSearchResult, server: UUID) -> SidebarItem {
        result.isBotChat ? .bot(server: server, profile: result.entry.profile)
            : .history(server: server, id: result.entry.id)
    }

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A new search when the query, the profile or the server changes.
    private var searchKey: String {
        guard let server = model.sessionsServer else { return query }
        return "\(server.id):\(server.connection.listProfile ?? ""):\(server.isConnected):\(query)"
    }
}

/// A search hit: the chat's title, the matched text with the query's words in bold, and
/// when the chat was last active.
struct SessionSearchRow: View {
    let result: SessionSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .lineLimit(1)
            if !result.hit.plainSnippet.isEmpty {
                Text(snippet)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let date = result.hit.date {
                SessionRelativeTime(date: date)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessionSearchRow")
    }

    private var title: String {
        if result.isBotChat { return Bot.chatTitle }
        if let title = result.entry.summary.title, !title.isEmpty { return title }
        return "Untitled chat"
    }

    /// The snippet, matched words in bold and the primary colour, after whose message it is.
    private var snippet: AttributedString {
        var text = AttributedString()
        if let speaker {
            text += AttributedString(speaker + ": ")
        }
        for segment in result.hit.snippetSegments {
            var run = AttributedString(segment.text)
            if segment.isMatch {
                // Bold in the row's own font, which follows the text size settings.
                run.inlinePresentationIntent = .stronglyEmphasized
                run.foregroundColor = .primary
            }
            text += run
        }
        return text
    }

    private var speaker: String? {
        switch result.hit.role {
        case "user": "You"
        case "assistant": "Hermes"
        default: nil
        }
    }
}
