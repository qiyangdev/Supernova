import Foundation
import Observation
import OpenAI
import SwiftUI

@MainActor
@Observable
final class ConversationEditor {
    typealias Responder =
        @MainActor (CreateModelResponseQuery, (String) -> Void, (Int) -> Void) async throws -> Void

    enum Failure: Error, Equatable {
        case missingAPIKey
        case interrupted
        case requestFailed
    }

    private struct RenderedTurn {
        let turn: ConversationTurn
        let reply: AttributedString
    }

    private(set) var document = AttributedString()
    private(set) var isResponding = false
    private(set) var isWaitingForReply = false
    private(set) var followsReplyAtEnd = true
    private(set) var lastContextUsage: ContextWindowUsage?
    var retryRequest: Int?
    var failure: Failure?

    private var committedText = AttributedString()
    private var turns: [RenderedTurn] = []
    private var draft: String
    private let respond: Responder
    private let onDraftChange: (String) -> Void
    private let onTurnCommitted: (ConversationTurn, ContextWindowUsage?) -> Void
    @ObservationIgnored private var responseTask: Task<Void, Never>?

    init(
        messages: [ConversationMessage] = [],
        draft: String = "",
        lastContextUsage: ContextWindowUsage? = nil,
        onDraftChange: @escaping (String) -> Void = { _ in },
        onTurnCommitted: @escaping (ConversationTurn, ContextWindowUsage?) -> Void = { _, _ in },
        respond: @escaping Responder = ConversationEditor.streamResponse
    ) {
        self.draft = draft
        self.lastContextUsage = lastContextUsage
        self.onDraftChange = onDraftChange
        self.onTurnCommitted = onTurnCommitted
        self.respond = respond

        var prompt: ConversationMessage?
        for message in messages {
            switch message.role {
            case .user:
                prompt = message
            case .assistant:
                guard let user = prompt else { continue }
                let turn = ConversationTurn(
                    position: user.position,
                    prompt: user.text,
                    reply: message.text,
                    status: message.replyStatus
                )
                turns.append(RenderedTurn(turn: turn, reply: MarkdownReply.render(turn.reply)))
                prompt = nil
            case nil:
                continue
            }
        }
        refreshDocument()
    }

    var text: String { String(document.characters) }

    var draftStartUTF16Offset: Int { committedText.utf16.count }

    var canSend: Bool {
        !isResponding
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func updateText(_ newText: String) {
        guard !isResponding,
            newText.hasPrefix(String(committedText.characters)),
            newText != text
        else { return }
        draft = String(newText.dropFirst(committedText.characters.count))
        document = committedText + AttributedString(draft)
        onDraftChange(draft)
    }

    @discardableResult
    func send(
        model: Model, effort: ModelSpec.ReasoningEffort, fastMode: Bool = false
    ) -> Task<Void, Never>? {
        guard canSend else { return nil }
        let turn = ConversationTurn(
            position: (turns.last?.turn.position ?? -2) + 2,
            prompt: draft.trimmingCharacters(in: .whitespacesAndNewlines),
            reply: "",
            status: .completed
        )
        return respond(
            to: turn, at: turns.endIndex, retry: false, model: model, effort: effort, fastMode: fastMode
        )
    }

    @discardableResult
    func retry(
        position: Int, model: Model, effort: ModelSpec.ReasoningEffort, fastMode: Bool = false
    ) -> Task<Void, Never>? {
        retryRequest = nil
        guard !isResponding,
            let index = turns.firstIndex(where: { $0.turn.position == position }),
            turns[index].turn.status != .completed
        else { return nil }
        return respond(
            to: turns[index].turn, at: index, retry: true, model: model, effort: effort, fastMode: fastMode
        )
    }

    func stop() {
        responseTask?.cancel()
    }

    private func respond(
        to original: ConversationTurn,
        at index: Int,
        retry: Bool,
        model: Model,
        effort: ModelSpec.ReasoningEffort,
        fastMode: Bool
    ) -> Task<Void, Never> {
        var history: [InputItem] = []
        for item in turns[..<index] where item.turn.status == .completed {
            history.append(.inputMessage(.init(role: .user, content: .textInput(item.turn.prompt))))
            history.append(.inputMessage(.init(role: .assistant, content: .textInput(item.turn.reply))))
        }
        history.append(.inputMessage(.init(role: .user, content: .textInput(original.prompt))))

        let spec = ModelSpec.all.first { $0.id == model }
        let reasoning: Components.Schemas.Reasoning? =
            spec?.reasoningEfforts.contains(effort) == true
            ? .init(effort: .init(effort)) : nil
        let query = CreateModelResponseQuery(
            input: .inputItemList(history),
            model: model,
            reasoning: reasoning,
            serviceTier: fastMode && model.supportsFastMode ? .priority : .defaultTier,
            store: false,
            stream: true
        )

        let prefix = renderTurns(turns[..<index]) + AttributedString(original.prompt + "\n\n")
        let suffix = retry
            ? AttributedString("\n\n") + renderTurns(turns[(index + 1)...]) + AttributedString(draft)
            : AttributedString()

        failure = nil
        followsReplyAtEnd = !retry
        isResponding = true
        isWaitingForReply = !retry
        if retry {
            let indicator = MarkdownViewAttachment(content: AnyView(RetryActivityView()))
            let previousReply = turns[index].reply
            let visibleReply = previousReply.characters.isEmpty
                ? AttributedString()
                : previousReply + AttributedString("\n\n")
            document = prefix + visibleReply + indicator.attributedText + suffix
        } else {
            document = prefix
        }

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                isWaitingForReply = false
                isResponding = false
                responseTask = nil
            }

            var reply = ""
            var formattedReply = AttributedString()
            var imageAttachments: [MarkdownImage: AttributedString] = [:]
            var requestFailure: Failure?
            var usage: ContextWindowUsage?
            do {
                try Task.checkCancellation()
                try await respond(query, { delta in
                    guard !Task.isCancelled, !delta.isEmpty else { return }
                    reply.append(delta)
                    if formattedReply.characters.isEmpty {
                        guard reply.contains(where: { !$0.isWhitespace }) else { return }
                        self.isWaitingForReply = false
                    }
                    formattedReply = MarkdownReply.render(reply) { image in
                        if let attachment = imageAttachments[image] { return attachment }
                        let attachment = MarkdownImageAttachment(image: image).attributedText
                        imageAttachments[image] = attachment
                        return attachment
                    }
                    self.document = prefix + formattedReply + suffix
                }, { totalTokens in
                    guard !Task.isCancelled else { return }
                    usage = ContextWindowUsage(model: model, totalTokens: totalTokens)
                })
            } catch {
                requestFailure = error as? Failure ?? .requestFailed
            }

            if requestFailure == .missingAPIKey, !Task.isCancelled {
                failure = .missingAPIKey
                refreshDocument()
                return
            }

            var turn = original
            let receivedReply = reply.contains { !$0.isWhitespace }
            if Task.isCancelled {
                turn.status = .stopped
            } else if requestFailure == .interrupted || (requestFailure != nil && receivedReply) {
                turn.status = .interrupted
            } else if requestFailure != nil || !receivedReply {
                turn.status = .failed
            } else {
                turn.status = .completed
            }
            if receivedReply {
                turn.reply = reply
            }

            let rendered = RenderedTurn(
                turn: turn,
                reply: retry && !receivedReply ? turns[index].reply : formattedReply
            )
            if retry {
                turns[index] = rendered
            } else {
                turns.append(rendered)
                draft = ""
            }
            refreshDocument()
            if let usage { lastContextUsage = usage }
            onTurnCommitted(turn, usage)
        }
        responseTask = task
        return task
    }

    private func refreshDocument() {
        committedText = renderTurns(turns[...])
        document = committedText + AttributedString(draft)
    }

    private func renderTurns(_ items: ArraySlice<RenderedTurn>) -> AttributedString {
        var text = AttributedString()
        for item in items {
            text += AttributedString(item.turn.prompt + "\n\n")
            if !item.reply.characters.isEmpty {
                text += item.reply + AttributedString("\n\n")
            }
            if item.turn.status != .completed {
                let position = item.turn.position
                let statusView = ReplyStatusView(
                    status: item.turn.status,
                    isRetryDisabled: { [weak self] in self?.isResponding != false },
                    retry: { [weak self] in self?.retryRequest = position }
                )
                text += MarkdownViewAttachment(content: AnyView(statusView)).attributedText
                text += AttributedString("\n\n")
            }
        }
        return text
    }

    private static func streamResponse(
        _ query: CreateModelResponseQuery,
        onDelta: (String) -> Void,
        onUsage: (Int) -> Void
    ) async throws {
        guard let key = try await OpenAIKeyStore.shared.load(), !key.isEmpty
        else {
            throw Failure.missingAPIKey
        }
        try Task.checkCancellation()

        let client = OpenAI(apiToken: key)
        var receivedText = false
        for try await event in client.responses.createResponseStreaming(
            query: query
        ) {
            try Task.checkCancellation()
            switch event {
            case .outputText(.delta(let event)):
                if !event.delta.isEmpty { receivedText = true }
                onDelta(event.delta)
            case .refusal(.delta(let event)):
                if !event.delta.isEmpty { receivedText = true }
                onDelta(event.delta)
            case .completed(let event):
                if let usage = event.response.usage { onUsage(usage.totalTokens) }
                if !receivedText, let text = event.response.outputText {
                    onDelta(text)
                }
                return
            case .incomplete(let event):
                if let usage = event.response.usage { onUsage(usage.totalTokens) }
                if !receivedText, let text = event.response.outputText {
                    onDelta(text)
                }
                throw Failure.interrupted
            case .failed(let event):
                if let usage = event.response.usage { onUsage(usage.totalTokens) }
                throw Failure.requestFailed
            case .error:
                throw Failure.requestFailed
            default:
                break
            }
        }
        try Task.checkCancellation()
        throw Failure.interrupted
    }
}
