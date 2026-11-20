import Foundation
import Observation
import OpenAI

@MainActor
@Observable
final class ConversationEditor {
    typealias Responder =
        @MainActor (CreateModelResponseQuery, (String) -> Void) async throws ->
        Void

    enum Failure: Error, Equatable {
        case missingAPIKey
        case interrupted
        case noReply
        case requestFailed
    }

    private(set) var document = AttributedString()
    private(set) var isResponding = false
    private(set) var isWaitingForReply = false
    var failure: Failure?

    private var committedText = AttributedString()
    private var history: [InputItem] = []
    private let respond: Responder
    @ObservationIgnored private var responseTask: Task<Void, Never>?

    init(respond: @escaping Responder = ConversationEditor.streamResponse) {
        self.respond = respond
    }

    var text: String { String(document.characters) }

    var draftStartUTF16Offset: Int { committedText.utf16.count }

    private var draft: String {
        String(document.characters.dropFirst(committedText.characters.count))
    }

    var canSend: Bool {
        !isResponding
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func updateText(_ newText: String) {
        guard !isResponding,
            newText.hasPrefix(String(committedText.characters)),
            newText != text
        else { return }
        document =
            committedText
            + AttributedString(
                String(newText.dropFirst(committedText.characters.count))
            )
    }

    @discardableResult
    func send(model: Model, effort: ModelSpec.ReasoningEffort) -> Task<
        Void, Never
    >? {
        guard canSend else { return nil }

        let originalDocument = document
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyPrefix = committedText + AttributedString(prompt + "\n\n")
        let message = InputItem.inputMessage(
            .init(role: .user, content: .textInput(prompt))
        )
        let spec = ModelSpec.all.first { $0.id == model }
        let reasoning: Components.Schemas.Reasoning? =
            spec?.reasoningEfforts.contains(effort) == true
            ? .init(effort: .init(effort)) : nil
        let query = CreateModelResponseQuery(
            input: .inputItemList(history + [message]),
            model: model,
            reasoning: reasoning,
            store: false,
            stream: true
        )

        failure = nil
        isResponding = true
        isWaitingForReply = true
        document = replyPrefix

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
            do {
                try await respond(query) { delta in
                    guard !Task.isCancelled, !delta.isEmpty else { return }
                    reply.append(delta)
                    if self.isWaitingForReply {
                        guard reply.contains(where: { !$0.isWhitespace }) else {
                            return
                        }
                        self.isWaitingForReply = false
                    }
                    formattedReply = MarkdownReply.render(reply) { image in
                        if let attachment = imageAttachments[image] { return attachment }
                        let attachment = MarkdownImageAttachment(image: image).attributedText
                        imageAttachments[image] = attachment
                        return attachment
                    }
                    self.document = replyPrefix + formattedReply
                }
                if reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty, !Task.isCancelled
                {
                    failure = .noReply
                }
            } catch {
                if !Task.isCancelled {
                    failure = error as? Failure ?? .requestFailed
                }
            }

            if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                document = originalDocument
            } else {
                history.append(message)
                history.append(
                    .inputMessage(
                        .init(role: .assistant, content: .textInput(reply))
                    )
                )
                committedText =
                    replyPrefix + formattedReply + AttributedString("\n\n")
                document = committedText
            }
        }
        responseTask = task
        return task
    }

    func stop() {
        responseTask?.cancel()
    }

    private static func streamResponse(
        _ query: CreateModelResponseQuery,
        onDelta: (String) -> Void
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
                if !receivedText, let text = event.response.outputText {
                    onDelta(text)
                }
                return
            case .incomplete:
                throw Failure.interrupted
            case .failed, .error:
                throw Failure.requestFailed
            default:
                break
            }
        }
        try Task.checkCancellation()
        throw Failure.interrupted
    }
}
