import Foundation
import SwiftData

enum ReplyStatus: String {
    case completed
    case stopped
    case interrupted
    case failed
}

struct ConversationTurn {
    let position: Int
    let prompt: String
    var reply: String
    var status: ReplyStatus
}

@Model
final class ConversationThread {
    var id: UUID
    var title: String
    var updatedAt: Date
    var draft: String
    var lastUsageModel: String?
    var lastUsageTokenCount: Int?
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

    var lastContextUsage: ContextWindowUsage? {
        guard let lastUsageModel, let lastUsageTokenCount else { return nil }
        return ContextWindowUsage(model: lastUsageModel, totalTokens: lastUsageTokenCount)
    }

    func saveTurn(_ turn: ConversationTurn, usage: ContextWindowUsage?) {
        if let reply = messages.first(where: { $0.position == turn.position + 1 }) {
            reply.text = turn.reply
            reply.replyStatusValue = turn.status.rawValue
        } else {
            messages.append(ConversationMessage(
                role: .user, text: turn.prompt, position: turn.position
            ))
            messages.append(ConversationMessage(
                role: .assistant, text: turn.reply, position: turn.position + 1,
                replyStatusValue: turn.status.rawValue
            ))
            draft = ""
        }
        if let usage {
            lastUsageModel = usage.model
            lastUsageTokenCount = usage.totalTokens
        }
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
    var replyStatusValue: String?

    init(role: Role, text: String, position: Int, replyStatusValue: String? = nil) {
        roleValue = role.rawValue
        self.text = text
        self.position = position
        self.replyStatusValue = replyStatusValue
    }

    var role: Role? { Role(rawValue: roleValue) }
    var replyStatus: ReplyStatus {
        replyStatusValue.flatMap(ReplyStatus.init(rawValue:)) ?? .completed
    }
}
