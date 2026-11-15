// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

final class SlashCommandTests: XCTestCase {
    func testQueryExtraction() {
        XCTAssertEqual(SlashCommandItem.query(from: "/"), "")
        XCTAssertEqual(SlashCommandItem.query(from: "/co"), "co")
        XCTAssertNil(SlashCommandItem.query(from: "hello"))
        XCTAssertNil(SlashCommandItem.query(from: "/clear now"))
        XCTAssertNil(SlashCommandItem.query(from: "/clear\nmore"))
    }

    func testItemsIncludeBuiltInsAndSkillsAndFilterByPrefix() {
        let skill = Skill(
            name: "translator",
            emoji: "🌐",
            summary: "Translate text accurately",
            instructions: "Translate to Chinese."
        )
        let all = SlashCommandItem.items(
            for: "",
            thinkingCapable: true,
            thinkingEnabled: false,
            skills: [skill]
        )
        XCTAssertEqual(all.map(\.command), ["clear", "compact", "new", "think", "translator"])
        XCTAssertEqual(all.last?.isSkill, true)
        XCTAssertEqual(all.last?.emoji, "🌐")

        let filtered = SlashCommandItem.items(
            for: "c",
            thinkingCapable: true,
            thinkingEnabled: false,
            skills: [skill]
        )
        XCTAssertTrue(filtered.contains { $0.command == "clear" })
        XCTAssertTrue(filtered.contains { $0.command == "compact" })

        let unknown = SlashCommandItem.items(
            for: "zzzznotacommand",
            thinkingCapable: true,
            thinkingEnabled: false,
            skills: [skill]
        )
        XCTAssertTrue(unknown.isEmpty)

        let noThink = SlashCommandItem.items(
            for: "think",
            thinkingCapable: false,
            thinkingEnabled: false,
            skills: []
        )
        XCTAssertTrue(noThink.isEmpty)
    }

    @MainActor
    func testClearActiveConversationResetsMessagesAndCompactionState() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ConversationStore(directory: dir)
        let defaults = UserDefaults(suiteName: "SlashCommandTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let chat = ChatStore(store: store, settings: settings)
        let convo = try XCTUnwrap(chat.newConversation())
        let m1 = Message(role: .user, answer: "hello")
        let m2 = Message(role: .assistant, answer: "hi")
        chat.conversations[0].messages = [m1, m2]
        chat.conversations[0].compactionSummary = "summary"
        chat.conversations[0].compactionCutoffMessageID = m1.id
        XCTAssertEqual(chat.activeID, convo.id)

        XCTAssertTrue(chat.clearActiveConversation())
        XCTAssertTrue(chat.conversations[0].messages.isEmpty)
        XCTAssertNil(chat.conversations[0].compactionSummary)
        XCTAssertNil(chat.conversations[0].compactionCutoffMessageID)
    }
}
