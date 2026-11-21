import Foundation
import SwiftData

@Model
final class ConversationThread {
    var id: UUID
    var title: String
    var updatedAt: Date
    var draft: String
    @Relationship(deleteRule: .cascade, inverse: \ConversationMessage.thread)
    var messages: [ConversationMessage] = []

    init(title: String = String(localized: "New Thread")) {
        id = UUID()
        self.title = title
        updatedAt = .now
        draft = ""
    }

    var transcript: [ConversationMessage] {
        messages.sorted { $0.position < $1.position }
    }

    func appendTurn(prompt: String, reply: String) {
        let position = messages.count
        messages.append(ConversationMessage(role: .user, text: prompt, position: position))
        messages.append(ConversationMessage(role: .assistant, text: reply, position: position + 1))
        draft = ""
        updatedAt = .now
    }
}

@Model
final class ConversationMessage {
    enum Role: String {
        case user
        case assistant
    }

    var roleValue: String
    var text: String
    var position: Int
    var thread: ConversationThread?

    init(role: Role, text: String, position: Int) {
        roleValue = role.rawValue
        self.text = text
        self.position = position
    }

    var role: Role? { Role(rawValue: roleValue) }
}
