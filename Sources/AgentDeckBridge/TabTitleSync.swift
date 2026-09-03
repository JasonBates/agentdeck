import Foundation

// MARK: - Keep Herdr tab labels aligned with AgentDeck's model-written titles

/// AgentDeck may improve a title several times while a young session acquires context.
/// Once it names an otherwise unnamed Herdr tab, this keeps the tab following those
/// improvements. A human rename is an ownership boundary: if Herdr's current label no
/// longer matches the last label written here, AgentDeck forgets the tab and leaves it
/// alone. Clearing the label makes it eligible again.
final class TabTitleSync {
    struct Observation {
        var tabId: String
        var currentLabel: String
        var modelTitle: String?
        var agentCount: Int
    }

    private struct StoredState: Codable {
        var version = 1
        var managed: [String: String]
    }

    typealias Rename = (_ tabId: String, _ title: String) throws -> Void

    private let stateURL: URL
    private let rename: Rename
    private let report: (String) -> Void
    private var managed: [String: String]

    static var defaultStateURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/state/agentdeck/tab-titles.json")
    }

    init(stateURL: URL = TabTitleSync.defaultStateURL,
         rename: @escaping Rename,
         report: @escaping (String) -> Void = { message in
             FileHandle.standardError.write(Data("tab title sync: \(message)\n".utf8))
         }) {
        self.stateURL = stateURL
        self.rename = rename
        self.report = report
        self.managed = Self.load(from: stateURL)
    }

    /// Builds one observation per Herdr tab. A tab with more than one detected agent is
    /// deliberately ambiguous: AgentDeck has one card title per agent but Herdr has one
    /// label per tab, so neither title gets to win silently.
    func reconcile(snapshot: HerdrSnapshot, deckAgents: [DeckAgent]) {
        let cardsByPane = Dictionary(uniqueKeysWithValues: deckAgents.map { ($0.paneId, $0) })
        let agentsByTab = Dictionary(grouping: snapshot.agents, by: \HerdrAgent.tabId)
        let observations = snapshot.tabs.map { tab -> Observation in
            let agents = agentsByTab[tab.tabId] ?? []
            let modelTitle: String?
            if agents.count == 1,
               let card = cardsByPane[agents[0].paneId],
               card.titleSource == "model" {
                modelTitle = card.title
            } else {
                modelTitle = nil
            }
            return Observation(tabId: tab.tabId,
                               currentLabel: tab.label ?? "",
                               modelTitle: modelTitle,
                               agentCount: agents.count)
        }
        reconcile(observations)
    }

    /// Internal entry point kept small and deterministic so ownership and persistence
    /// rules can be tested without a live Herdr session.
    func reconcile(_ observations: [Observation]) {
        let liveTabs = Set(observations.map(\.tabId))
        let beforePrune = managed.count
        managed = managed.filter { liveTabs.contains($0.key) }
        var changed = managed.count != beforePrune

        for tab in observations where tab.agentCount == 1 {
            guard let rawTitle = tab.modelTitle else { continue }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != "—" else { continue }

            if let lastWritten = managed[tab.tabId] {
                guard tab.currentLabel == lastWritten else {
                    // The label changed somewhere other than this synchroniser. Treat it
                    // as a manual rename and do not reclaim it on later title updates.
                    managed.removeValue(forKey: tab.tabId)
                    changed = true
                    continue
                }
                guard title != lastWritten else { continue }
            } else {
                // Claim only an unnamed tab, or recover ownership after a lost state file
                // when Herdr already carries the exact title AgentDeck just generated.
                // Herdr represents an unnamed tab with its ordinal ("1", "2", …), not
                // an empty label. Its public number is not the same representation as
                // that visible ordinal, so recognize the label itself rather than trying
                // to compare the two numbering systems.
                let defaultLabel = tab.currentLabel.isEmpty
                    || tab.currentLabel.allSatisfy { $0.isNumber }
                guard defaultLabel || tab.currentLabel == title else { continue }
                if tab.currentLabel == title {
                    managed[tab.tabId] = title
                    changed = true
                    continue
                }
            }

            do {
                try rename(tab.tabId, title)
                managed[tab.tabId] = title
                changed = true
            } catch {
                report("could not rename \(tab.tabId): \(error)")
            }
        }

        if changed { save() }
    }

    private static func load(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(StoredState.self, from: data),
              state.version == 1
        else { return [:] }
        return state.managed
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(StoredState(managed: managed))
            try data.write(to: stateURL, options: .atomic)
        } catch {
            report("could not save ownership state: \(error)")
        }
    }
}
