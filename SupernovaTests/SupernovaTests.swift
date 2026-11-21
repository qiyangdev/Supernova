//
//  SupernovaTests.swift
//  SupernovaTests
//
//  Created by qiyang on 2026/11/20.
//

import Foundation
import OpenAI
import SwiftData
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@testable import Supernova

struct SupernovaTests {

    @MainActor
    @Test func conversationsRestoreTheirDraftsAndRawMarkdownFromDisk() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appending(path: "Conversations.store"))
        let markdown = "# Saved heading\n\n**Saved reply**"

        do {
            let container = try ModelContainer(for: ConversationThread.self, configurations: configuration)
            let context = container.mainContext
            let first = ConversationThread(title: "First")
            let second = ConversationThread(title: "Second")
            context.insert(first)
            context.insert(second)

            let editor = ConversationEditor(
                onDraftChange: { first.draft = $0 },
                onTurnCommitted: { first.saveTurn($0, usage: $1) },
                respond: { _, append, reportUsage in
                    append(markdown)
                    reportUsage(210_000)
                }
            )
            editor.updateText("First prompt")
            #expect(first.draft == "First prompt")
            let task = try #require(editor.send(model: .gpt6_sol, effort: .low))
            await task.value
            #expect(first.draft.isEmpty)
            editor.updateText(editor.text + "First draft")
            second.draft = "Second draft"
            try context.save()
        }

        let reopened = try ModelContainer(for: ConversationThread.self, configurations: configuration)
        let context = reopened.mainContext
        let threads = try context.fetch(FetchDescriptor<ConversationThread>())
        let first = try #require(threads.first { $0.title == "First" })
        let second = try #require(threads.first { $0.title == "Second" })
        #expect(first.transcript.map(\.text) == ["First prompt", markdown])
        #expect(second.transcript.isEmpty)
        #expect(second.draft == "Second draft")

        #expect(first.lastContextUsage == ContextWindowUsage(model: .gpt6_sol, totalTokens: 210_000))
        #expect(second.lastContextUsage == nil)
        var request: CreateModelResponseQuery?
        let editor = ConversationEditor(
            messages: first.transcript, draft: first.draft, lastContextUsage: first.lastContextUsage
        ) { query, append, _ in
            request = query
            append("Done")
        }
        #expect(editor.lastContextUsage?.fraction == 0.2)
        #expect(editor.text == "First prompt\n\nSaved heading\n\nSaved reply\n\nFirst draft")
        let task = try #require(editor.send(model: .gpt6_sol, effort: .low))
        await task.value
        #expect(request?.serviceTier == .defaultTier)
        #expect(editor.lastContextUsage == first.lastContextUsage)
        #expect(request?.input == .inputItemList([
            .inputMessage(.init(role: .user, content: .textInput("First prompt"))),
            .inputMessage(.init(role: .assistant, content: .textInput(markdown))),
            .inputMessage(.init(role: .user, content: .textInput("First draft"))),
        ]))

        context.delete(first)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ConversationMessage>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ConversationThread>()) == 1)
    }

    @MainActor
    @Test func conversationAppendsEachDeltaAndReusesTheCompletedTurn()
        async throws
    {
        weak var observedEditor: ConversationEditor?
        var requests: [CreateModelResponseQuery] = []
        let editor = ConversationEditor { query, append, _ in
            requests.append(query)
            if requests.count == 1 {
                #expect(observedEditor?.isWaitingForReply == true)
                #expect(observedEditor?.text == "Hello\n\n")
                append("\n")
                #expect(observedEditor?.isWaitingForReply == true)
                append("First")
                #expect(observedEditor?.isWaitingForReply == false)
                #expect(observedEditor?.text == "Hello\n\nFirst")
                append(" reply")
                #expect(observedEditor?.text == "Hello\n\nFirst reply")
            } else {
                append("Second reply")
            }
        }
        observedEditor = editor

        editor.updateText("Hello\n")
        let first = try #require(editor.send(model: .gpt6_sol, effort: .low))
        #expect(editor.send(model: .gpt6_sol, effort: .low) == nil)
        await first.value
        #expect(editor.text == "Hello\n\nFirst reply\n\n")
        #expect(!editor.canSend)

        let committedText = editor.text
        editor.updateText(committedText + "Draft")
        editor.updateText(committedText)
        editor.updateText(String(committedText.dropLast()))
        #expect(editor.text == committedText)
        #expect(editor.draftStartUTF16Offset == committedText.utf16.count)

        editor.updateText(editor.text + "Follow up")
        let second = try #require(editor.send(model: .gpt6_sol, effort: .low))
        await second.value
        #expect(
            editor.text
                == "Hello\n\nFirst reply\n\nFollow up\n\nSecond reply\n\n"
        )

        let request = try #require(requests.last)
        #expect(request.model == .gpt6_sol)
        #expect(request.reasoning?.effort == .low)
        #expect(request.stream == true)
        #expect(request.store == false)
        #expect(
            request.input
                == .inputItemList([
                    .inputMessage(
                        .init(role: .user, content: .textInput("Hello"))
                    ),
                    .inputMessage(
                        .init(
                            role: .assistant,
                            content: .textInput("\nFirst reply")
                        )
                    ),
                    .inputMessage(
                        .init(role: .user, content: .textInput("Follow up"))
                    ),
                ])
        )
    }

    @MainActor
    @Test func markdownFormatsStreamingRepliesAndKeepsSourceInHistory()
        async throws
    {
        let openingChunk = "````markdown\n# Heading\n\n**Bo"
        let markdown =
            "````markdown\n# Heading\n\n**Bold**, *italic*, ~~strike~~ and `code`.\n\n"
            + "- First\n- Second\n\n3. Third\n\n> Quote\n\n"
            + "```swift\nlet value = 1\n```\n\n[Link](https://example.com)\n````"
        var requests: [CreateModelResponseQuery] = []
        weak var observedEditor: ConversationEditor?
        let editor = ConversationEditor { query, append, _ in
            requests.append(query)
            if requests.count == 1 {
                append(openingChunk)
                #expect(
                    observedEditor?.text == "# Plain prompt\n\nHeading\n\n**Bo"
                )
                append(String(markdown.dropFirst(openingChunk.count)))
            } else {
                append("Done")
            }
        }
        observedEditor = editor
        editor.updateText("# Plain prompt")
        let first = try #require(editor.send(model: .gpt6_sol, effort: .low))
        await first.value

        #expect(
            editor.text
                == "# Plain prompt\n\nHeading\n\nBold, italic, strike and code.\n\n"
                + "• First\n• Second\n\n3. Third\n\n│ Quote\n\nlet value = 1\n\nLink\n\n"
        )
        #expect(
            editor.document.runs.contains {
                $0.link?.absoluteString == "https://example.com"
            }
        )

        editor.updateText(editor.text + "Next")
        let second = try #require(editor.send(model: .gpt6_sol, effort: .low))
        await second.value
        #expect(editor.text.hasSuffix("\n\nNext\n\nDone\n\n"))
        #expect(
            requests.last?.input
                == .inputItemList([
                    .inputMessage(
                        .init(
                            role: .user,
                            content: .textInput("# Plain prompt")
                        )
                    ),
                    .inputMessage(
                        .init(role: .assistant, content: .textInput(markdown))
                    ),
                    .inputMessage(
                        .init(role: .user, content: .textInput("Next"))
                    ),
                ])
        )
    }

    @MainActor
    @Test func rendersMarkdownExamplesBetweenParagraphsAndPreservesCode() {
        let python = MarkdownReply.render("```python\n# Comment\nprint(1)\n```")
        #expect(String(python.characters) == "# Comment\nprint(1)")
        let example = MarkdownReply.render(
            "```md\n# Example\n```\n\nMore text."
        )
        #expect(String(example.characters) == "Example\n\nMore text.")
        for fence in ["```markdown", "```"] {
            let intro = "Here are a few Markdown examples:"
            let sample =
                "\(intro)\n\n\(fence)\n# Heading\n\n**Bold**\n\n- First\n- Second"
            let expected = "\(intro)\n\nHeading\n\nBold\n\n• First\n• Second"
            #expect(String(MarkdownReply.render(sample).characters) == expected)
            #expect(
                String(
                    MarkdownReply.render(sample + "\n```\n\nDone.").characters
                ) == expected + "\n\nDone."
            )
        }
        let unlabeledCode = MarkdownReply.render(
            "```\n# Comment\nprint(1)\n```"
        )
        #expect(String(unlabeledCode.characters) == "# Comment\nprint(1)")
        let wrapped = MarkdownReply.render("~~~md\n# Heading\n~~~")
        #expect(String(wrapped.characters) == "Heading")
    }

    @MainActor
    @Test func markdownTablesCreateInlineViewsInsideAndOutsideFences() throws {
        let table = """
            | Name | Count | Note |
            | :--- | ---: | :---: |
            | **Alex** | 7 | A \\| B |
            | Jamie | 120 |
            """
        for source in [
            table,
            "```markdown\n\(table)\n```",
            "```text\n\(table)\n```",
            "Results:\n\n```\n\(table)\n```\n\nDone.",
        ] {
            let rendered = MarkdownReply.render(source)
            let native = NSAttributedString(rendered)
            var tableAttachment: MarkdownTableAttachment?
            native.enumerateAttribute(.attachment, in: NSRange(location: 0, length: native.length)) {
                value, _, stop in
                if let attachment = value as? MarkdownTableAttachment {
                    tableAttachment = attachment
                    stop.pointee = true
                }
            }
            let attachment = try #require(tableAttachment)
            #expect(attachment.table.rows.map { $0.map { String($0.characters) } } == [
                ["Name", "Count", "Note"], ["Alex", "7", "A | B"], ["Jamie", "120", ""]
            ])
            #expect(attachment.table.columns.map(\.alignment) == [.left, .right, .center])
        }
        let code = MarkdownReply.render("```python\n\(table)\n```")
        #expect(String(code.characters) == table)
    }

    @MainActor
    @Test func markdownImagesUseViewAttachmentsAndKeepAlternativeText() {
        let source = """
            Above.

            ![A **bold** label](https://example.com/photo.png)

            ![](https://example.com/photo.png)![](https://example.com/photo.png)

            ![Relative image](local.png)

            Below.
            """
        let rendered = MarkdownReply.render(source)
        #expect(String(rendered.characters) == "Above.\n\n\u{FFFC}\n\n\u{FFFC}\n\u{FFFC}\n\nRelative image\n\nBelow.")
        let native = NSAttributedString(rendered)
        var images: [MarkdownImage] = []
        native.enumerateAttribute(.attachment, in: NSRange(location: 0, length: native.length)) {
            value, _, _ in
            if let attachment = value as? MarkdownImageAttachment {
                images.append(attachment.markdownImage)
            }
        }
        #expect(images.map(\.alternativeText) == ["A bold label", "", ""])
        #expect(images.allSatisfy { $0.url.absoluteString == "https://example.com/photo.png" })
    }

    @MainActor
    @Test func markdownImagesKeepTheirLoadedStateAcrossViewAppearances() async throws {
        let url = try #require(URL(string: "https://example.com/photo.png"))
        var fetches = 0
        let loader = MarkdownImageLoader(url: url) { _ in
            fetches += 1
            return Image(systemName: "photo")
        }

        let firstAppearance = try #require(loader.loadIfNeeded())
        let secondAppearance = try #require(loader.loadIfNeeded())
        await firstAppearance.value
        await secondAppearance.value
        #expect(loader.loadIfNeeded() == nil)
        #expect(fetches == 1)
        guard case .success = loader.phase else {
            Issue.record("Expected a retained loaded image")
            return
        }
    }

    @MainActor
    @Test func interruptedReplyRetriesInPlaceWithoutChangingLaterMessagesOrDraft() async throws {
        let container = try ModelContainer(
            for: ConversationThread.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let thread = ConversationThread(title: "Retries")
        container.mainContext.insert(thread)
        var requests: [CreateModelResponseQuery] = []
        let editor = ConversationEditor(
            onDraftChange: { thread.draft = $0 },
            onTurnCommitted: { thread.saveTurn($0, usage: $1) }
        ) { query, append, reportUsage in
            requests.append(query)
            switch requests.count {
            case 1:
                append("Partial reply")
                reportUsage(200)
                throw ConversationEditor.Failure.interrupted
            case 2:
                append("Later reply")
            case 3:
                throw ConversationEditor.Failure.requestFailed
            default:
                append("Recovered reply")
                reportUsage(350)
            }
        }
        editor.updateText("Original prompt")
        let first = try #require(editor.send(model: .gpt6_sol, effort: .low, fastMode: true))
        await first.value
        #expect(requests[0].serviceTier == .priority)
        let fastBody = try JSONSerialization.jsonObject(with: JSONEncoder().encode(requests[0]))
        #expect((fastBody as? [String: Any])?["service_tier"] as? String == "priority")
        #expect(thread.lastContextUsage == ContextWindowUsage(model: .gpt6_sol, totalTokens: 200))
        #expect(thread.transcript.last?.replyStatus == .interrupted)
        #expect(editor.text.contains("Partial reply"))

        editor.updateText(editor.text + "Later prompt")
        let later = try #require(editor.send(model: .gpt5_6_terra, effort: .low, fastMode: true))
        await later.value
        #expect(requests[1].serviceTier == .defaultTier)
        #expect(requests[1].input == .inputItemList([
            .inputMessage(.init(role: .user, content: .textInput("Later prompt"))),
        ]))
        editor.updateText(editor.text + "Keep this draft")

        let failedRetry = try #require(editor.retry(position: 0, model: .gpt6_sol, effort: .low))
        await failedRetry.value
        #expect(thread.transcript[1].replyStatus == .failed)
        #expect(thread.transcript[1].text == "Partial reply")
        #expect(thread.lastContextUsage == ContextWindowUsage(model: .gpt6_sol, totalTokens: 200))
        let retry = try #require(editor.retry(position: 0, model: .gpt6_astra, effort: .low, fastMode: true))
        await retry.value
        #expect(requests[3].serviceTier == .priority)
        #expect(editor.lastContextUsage == ContextWindowUsage(model: .gpt6_astra, totalTokens: 350))
        #expect(thread.lastContextUsage == editor.lastContextUsage)
        #expect(requests[3].input == .inputItemList([
            .inputMessage(.init(role: .user, content: .textInput("Original prompt"))),
        ]))
        #expect(thread.transcript.map(\.text) == [
            "Original prompt", "Recovered reply", "Later prompt", "Later reply",
        ])
        #expect(thread.transcript[1].replyStatus == .completed)
        #expect(thread.draft == "Keep this draft")
        #expect(editor.text == "Original prompt\n\nRecovered reply\n\nLater prompt\n\nLater reply\n\nKeep this draft")
    }

    @MainActor
    @Test func stoppingBeforeTheFirstChunkKeepsASingleRetryableTurn() async throws {
        let started = AsyncStream<Void>.makeStream()
        var saved: [ConversationTurn] = []
        var attempts = 0
        let editor = ConversationEditor(onTurnCommitted: { turn, _ in saved.append(turn) }) { _, append, _ in
            attempts += 1
            if attempts == 1 {
                started.continuation.yield(())
                try await Task.sleep(for: .seconds(30))
            } else {
                append("Retried reply")
            }
        }

        editor.updateText("Stop this reply")
        let first = try #require(editor.send(model: .gpt6_sol, effort: .low))
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        started.continuation.finish()
        editor.stop()
        await first.value
        #expect(saved.count == 1)
        #expect(saved.first?.status == .stopped)
        #expect(editor.text == "Stop this reply\n\n\u{FFFC}\n\n")
        #expect(!editor.canSend)

        let retry = try #require(editor.retry(position: 0, model: .gpt6_sol, effort: .low))
        await retry.value
        #expect(saved.map(\.position) == [0, 0])
        #expect(saved.last?.status == .completed)
        #expect(editor.text == "Stop this reply\n\nRetried reply\n\n")
    }

    @MainActor
    @Test func conversationKeepsTheDraftWhenTheRequestFailsBeforeReturningText()
        async throws
    {
        let editor = ConversationEditor { _, _, _ in
            throw ConversationEditor.Failure.missingAPIKey
        }
        editor.updateText("  Keep this draft  ")

        let request = try #require(editor.send(model: .gpt6_sol, effort: .low))
        await request.value

        #expect(editor.failure == .missingAPIKey)
        #expect(!editor.isWaitingForReply)
        #expect(editor.text == "  Keep this draft  ")
        #expect(editor.canSend)
    }

    @Test func openAIKeyPersistsAcrossStoresAndCanBeReplacedOrRemoved()
        async throws
    {
        let service = "dev.qiyang.Supernova.tests.\(UUID())"
        let writer = OpenAIKeyStore(service: service)
        let reader = OpenAIKeyStore(service: service)

        #expect(try await reader.load() == nil)

        try await writer.save("first-test-value")
        #expect(try await reader.load() == "first-test-value")

        try await writer.save("second-test-value")
        #expect(try await reader.load() == "second-test-value")

        try await writer.save("")
        #expect(try await reader.load() == nil)
    }

}
