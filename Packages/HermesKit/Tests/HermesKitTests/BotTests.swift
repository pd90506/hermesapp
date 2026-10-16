import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// A `profiles.list` row as `methods_profiles.py:290-297` builds it, with the
/// session fields of `_profile_session_fields` (:231-253) and the ui_meta fields
/// of `_profile_ui_meta_fields` (:256-278; `ui_meta` only when non-empty).
func profileRowPayload(_ name: String, isDefault: Bool = false, displayName: String = "",
                       canonical: JSONValue = nil, worker: JSONValue = nil, last: JSONValue = nil,
                       uiMeta: JSONValue? = nil, hasAvatar: Bool = false) -> JSONValue {
    var row: [String: JSONValue] = [
        "name": .string(name), "path": .string("/srv/hermes/profiles/\(name)"), "is_default": .bool(isDefault),
        "model": "test-model", "provider": "test-provider", "description": "", "display_name": .string(displayName),
        "skill_count": 3, "previous_names": [], "role": nil,
        "last_session": last, "worker_session": worker, "canonical_session": canonical,
        "ui_meta_revisions": [:], "has_avatar": .bool(hasAvatar),
    ]
    if let uiMeta { row["ui_meta"] = uiMeta }
    return .object(row)
}

/// `canonical_session` as `_canonical_session_row` returns it (`methods_profiles.py:188-193`).
func canonicalPayload(id: String, tip: String? = nil, preview: String = "", lastActive: Double = 0) -> JSONValue {
    ["id": .string(id), "resolved_id": .string(tip ?? id), "root_title": "Bot Chat", "title": "Bot Chat",
     "preview": .string(preview), "started_at": 1_700_000_000, "last_active": .number(lastActive),
     "message_count": 4, "live_message_count": 4]
}

@Suite struct BotTests {
    @Test func decodesTheHermesRosterAndPutsDefaultFirst() throws {
        let result: JSONValue = [
            "profiles": [
                profileRowPayload("coder", canonical: canonicalPayload(id: "c-root", tip: "c-tip", preview: "done!",
                                                                       lastActive: 1_700_000_100)),
                profileRowPayload("default", isDefault: true),
                profileRowPayload("daily_notes", worker: ["id": "w1", "source": "kanban", "title": "",
                                                          "last_active": 1_700_000_050]),
                profileRowPayload("finance", displayName: "Money", uiMeta: ["hermes-bots": ["title": "Ledger"]]),
            ],
            "bot_mode_protocol": true, "install_id": "abc",
        ]
        let profiles = try result.decode(ProfilesListResult.self).profiles
        let bots = Bot.roster(profiles)

        #expect(bots.map(\.name) == ["default", "coder", "daily_notes", "finance"])
        #expect(bots.map(\.displayName) == ["Hermes", "Coder", "Daily Notes", "Ledger"])
        let coder = bots[1]
        #expect(coder.hasChat && coder.preview == "done!")
        #expect(coder.chatStoredIDs == ["c-root", "c-tip"])
        #expect(coder.lastActive == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(!bots[0].hasChat && bots[0].preview == nil && bots[0].lastActive == nil)
        #expect(bots[2].profile.workerSession?.source == "kanban")
    }

    /// Desktop matches `root_title` first, plain `title` only without it (`canonical-chat.ts:196-204`).
    @Test func botChatRowMatchesOnRootTitleFirst() throws {
        func row(_ json: JSONValue) throws -> SessionSummary { try json.decode(SessionSummary.self) }
        #expect(Bot.isChatRow(try row(["id": "a", "title": "Bot Chat"])))
        #expect(Bot.isChatRow(try row(["id": "a", "title": "Bot Chat #2", "root_title": "Bot Chat"])))
        #expect(!Bot.isChatRow(try row(["id": "a", "title": "Bot Chat", "root_title": "Other"])))
        #expect(!Bot.isChatRow(try row(["id": "a", "title": "Groceries"])))
    }

    @Test func displayNameFallsBackToTheProfileDisplayName() {
        let bot = Bot(profile: ProfileRow(name: "researcher", displayName: "  Scout "))
        #expect(bot.displayName == "Scout")
    }

    @Test func botChatErrorsTellTheUserToRetry() {
        let message = GatewayConnection.describe(BotChatError.registryUnavailable(profile: "coder", detail: "timeout"))
        #expect(message.contains("coder") && message.contains("timeout") && message.contains("try again"))
        #expect(GatewayConnection.describe(BotChatError.registryUnconfirmed(profile: "coder")).contains("try again"))
    }

    @Test func activityUsesDesktopsWindowsAndLiveState() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func bot(chat: Double? = nil, worker: Double? = nil) -> Bot {
            Bot(profile: ProfileRow(name: "b",
                                    canonicalSession: chat.map { ProfileCanonicalSession(id: "s", lastActive: $0) },
                                    workerSession: worker.map { ProfileWorkerSession(id: "w", lastActive: $0) }))
        }
        #expect(bot().activity(now: now) == .idle)
        #expect(bot(chat: 1_000_000 - 60).activity(now: now) == .recent)
        #expect(bot(chat: 1_000_000 - 120).activity(now: now) == .idle)
        #expect(bot(worker: 1_000_000 - 140).activity(now: now) == .working)
        #expect(bot(worker: 1_000_000 - 160).activity(now: now) == .idle)
        #expect(bot().activity(now: now, liveTurnRunning: true) == .working)
        #expect(bot(worker: 1_000_000).activity(now: now, waitingForAnswer: true) == .waitingForYou)
    }
}
