//
//  SupernovaTests.swift
//  SupernovaTests
//
//  Created by qiyang on 2026/11/20.
//

import Foundation
import OpenAI
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
    @Test func conversationAppendsEachDeltaAndReusesTheCompletedTurn()
        async throws
    {
        weak var observedEditor: ConversationEditor?
        var requests: [CreateModelResponseQuery] = []
        let editor = ConversationEditor { query, append in
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
        let editor = ConversationEditor { query, append in
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
    @Test func conversationKeepsTheDraftWhenTheRequestFailsBeforeReturningText()
        async throws
    {
        let editor = ConversationEditor { _, _ in
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
