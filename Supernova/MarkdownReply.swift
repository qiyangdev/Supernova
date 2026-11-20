import SwiftUI

@MainActor
enum MarkdownReply {
    static func render(
        _ source: String,
        imageAttachment: @MainActor (MarkdownImage) -> AttributedString = {
            MarkdownImageAttachment(image: $0).attributedText
        }
    ) -> AttributedString {
        guard
            let markdown = try? AttributedString(
                markdown: source,
                options: .init(appliesSourcePositionAttributes: true)
            ),
            !markdown.characters.isEmpty
        else {
            return AttributedString(source)
        }
        let lines = source.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
        let rendered = render(markdown, sourceLines: lines, imageAttachment: imageAttachment)
        return rendered.characters.isEmpty ? AttributedString(source) : rendered
    }

    private static func render(
        _ markdown: AttributedString,
        sourceLines: [Substring] = [],
        imageAttachment: @MainActor (MarkdownImage) -> AttributedString
    ) -> AttributedString {
        var result = AttributedString()
        var previousBlock: [PresentationIntent.IntentType] = []
        var previousText = ""

        var runs = markdown.runs[...]
        while let run = runs.popFirst() {
            let block = run.presentationIntent?.components ?? []
            let text = String(markdown[run.range].characters)
            if block != previousBlock {
                if !result.characters.isEmpty {
                    let insideSameList = block.contains { component in
                        switch component.kind {
                        case .orderedList, .unorderedList:
                            previousBlock.contains {
                                $0.identity == component.identity
                            }
                        default:
                            false
                        }
                    }
                    let newlines = insideSameList ? 1 : 2
                    let existing = previousText.reversed().prefix(
                        while: \.isNewline
                    ).count
                    if existing < newlines {
                        result += AttributedString(
                            String(repeating: "\n", count: newlines - existing)
                        )
                    }
                }
                result += AttributedString(
                    prefix(for: block, after: previousBlock)
                )
            }
            let rendered: AttributedString
            if let table = block.first(where: {
                if case .table = $0.kind { return true }
                return false
            }), case .table(let columns) = table.kind {
                let remainingCells = runs.prefix {
                    $0.presentationIntent?.components.contains(table) == true
                }
                rendered = renderTable(
                    markdown,
                    runs: [run] + Array(remainingCells),
                    columns: columns
                )
                runs = runs[remainingCells.endIndex...]
            } else if let url = run.imageURL {
                let hasAlternativeText = text.contains { $0 != "\u{FFFC}" }
                if let image = MarkdownImage(url: url, alternativeText: hasAlternativeText ? text : "") {
                    if result.characters.last?.isNewline == false {
                        result += AttributedString("\n")
                    }
                    let attachment = imageAttachment(image)
                    var images = attachment
                    if !hasAlternativeText {
                        for _ in text.dropFirst() {
                            images += AttributedString("\n") + attachment
                        }
                    }
                    if runs.first?.presentationIntent?.components == block {
                        images += AttributedString("\n")
                    }
                    rendered = images
                } else {
                    rendered = AttributedString(
                        hasAlternativeText ? text : String(localized: "Image unavailable")
                    )
                }
            } else {
                rendered =
                    markdownExample(
                        text,
                        run: run,
                        block: block,
                        sourceLines: sourceLines,
                        imageAttachment: imageAttachment
                    ) ?? styled(text, run: run, block: block)
            }
            result += rendered
            previousBlock = block
            previousText = String(rendered.characters)
        }

        // Foundation includes a trailing line break in fenced code.
        while result.characters.last?.isNewline == true {
            result.characters.removeLast()
        }
        return result
    }

    private static func markdownExample(
        _ text: String,
        run: AttributedString.Runs.Run,
        block: [PresentationIntent.IntentType],
        sourceLines: [Substring],
        imageAttachment: @MainActor (MarkdownImage) -> AttributedString
    ) -> AttributedString? {
        guard !sourceLines.isEmpty,
            case .codeBlock(let language) = block.first?.kind
        else { return nil }

        let languageTag = language?.lowercased()
        let isMarkdown = languageTag == "markdown" || languageTag == "md"
        let isPlainText =
            languageTag == "text" || languageTag == "txt"
            || languageTag == "plaintext"
        if languageTag == nil {
            // An unlabeled fence needs evidence of Markdown before removing code styling.
            guard let startLine = run.markdownSourcePosition?.startLine,
                sourceLines.indices.contains(startLine - 1)
            else { return nil }
            let fence = sourceLines[startLine - 1].trimmingCharacters(
                in: .whitespaces
            )
            guard fence.count >= 3, let marker = fence.first,
                marker == "`" || marker == "~",
                fence.allSatisfy({ $0 == marker })
            else { return nil }
        } else if !isMarkdown && !isPlainText {
            return nil
        }

        guard let markdown = try? AttributedString(
            markdown: text, options: .init(appliesSourcePositionAttributes: true)
        ),
            !markdown.characters.isEmpty
        else { return nil }
        if isPlainText {
            guard markdown.runs.allSatisfy(isTableCell) else { return nil }
        } else if !isMarkdown {
            guard
                markdown.runs.contains(where: isTableCell)
                    || markdown.runs.contains(where: { $0.imageURL != nil })
                    || hasMixedMarkdownFormatting(markdown)
            else { return nil }
        }
        return render(markdown, imageAttachment: imageAttachment)
    }

    private static func isTableCell(_ run: AttributedString.Runs.Run) -> Bool {
        if case .tableCell = run.presentationIntent?.components.first?.kind {
            return true
        }
        return false
    }

    private static func renderTable(
        _ markdown: AttributedString,
        runs: [AttributedString.Runs.Run],
        columns: [PresentationIntent.TableColumn]
    ) -> AttributedString {
        var rows: [[AttributedString]] = []
        let emptyRow = Array(
            repeating: AttributedString(),
            count: columns.count
        )
        for run in runs {
            guard let components = run.presentationIntent?.components,
                components.count >= 2,
                case .tableCell(let column) = components[0].kind,
                columns.indices.contains(column)
            else { continue }

            let row: Int
            switch components[1].kind {
            case .tableHeaderRow:
                row = 0
            case .tableRow(let index):
                row = index
            default:
                continue
            }

            while rows.count <= row { rows.append(emptyRow) }
            rows[row][column] += styled(
                String(markdown[run.range].characters),
                run: run,
                block: components,
                baseFont: row == 0 ? .body.bold() : nil
            )
        }

        guard !rows.isEmpty else { return AttributedString() }
        return MarkdownTable(rows: rows, columns: columns).inlineAttachment()
    }

    private static func hasMixedMarkdownFormatting(_ markdown: AttributedString)
        -> Bool
    {
        var hasHeading = false
        var hasListOrQuote = false
        var hasInlineFormatting = false

        for run in markdown.runs {
            for component in run.presentationIntent?.components ?? [] {
                switch component.kind {
                case .header:
                    hasHeading = true
                case .listItem, .blockQuote:
                    hasListOrQuote = true
                default:
                    break
                }
            }
            let emphasis = run.inlinePresentationIntent?.intersection([
                .stronglyEmphasized, .emphasized, .strikethrough,
            ])
            if run.link != nil || emphasis?.isEmpty == false {
                hasInlineFormatting = true
            }
        }

        return (hasHeading && (hasListOrQuote || hasInlineFormatting))
            || (hasListOrQuote && hasInlineFormatting)
    }

    private static func prefix(
        for block: [PresentationIntent.IntentType],
        after previous: [PresentationIntent.IntentType]
    ) -> String {
        var prefix = ""
        var listDepth = 0
        for (index, component) in block.enumerated().reversed() {
            switch component.kind {
            case .blockQuote:
                prefix += "│ "
            case .listItem(let ordinal):
                listDepth += 1
                guard let list = block.dropFirst(index + 1).first else {
                    continue
                }
                if previous.contains(component) {
                    if !block.prefix(index).contains(where: {
                        if case .listItem = $0.kind { return true }
                        return false
                    }) {
                        prefix += "   "
                    }
                    continue
                }
                prefix += String(repeating: "   ", count: listDepth - 1)
                if case .orderedList = list.kind {
                    prefix += "\(ordinal). "
                } else {
                    prefix += "• "
                }
            default:
                break
            }
        }
        return prefix
    }

    private static func styled(
        _ text: String,
        run: AttributedString.Runs.Run,
        block: [PresentationIntent.IntentType],
        baseFont: Font? = nil
    ) -> AttributedString {
        var result = AttributedString(text)
        let inline = run.inlinePresentationIntent ?? []
        var font = baseFont ?? .body
        var hasFont = baseFont != nil

        switch block.first?.kind {
        case .header(let level):
            font = (level == 1 ? Font.title : level == 2 ? .title2 : .headline)
                .bold()
            hasFont = true
        case .codeBlock:
            font = .body.monospaced()
            result.backgroundColor = Color.secondary.opacity(0.12)
            hasFont = true
        default:
            break
        }

        if inline.contains(.code) {
            font = font.monospaced()
            result.backgroundColor = Color.secondary.opacity(0.12)
            hasFont = true
        }
        if inline.contains(.stronglyEmphasized) {
            font = font.bold()
            hasFont = true
        }
        if inline.contains(.emphasized) {
            font = font.italic()
            hasFont = true
        }
        if hasFont { result.font = font }
        if inline.contains(.strikethrough) {
            result.strikethroughStyle = .single
        }
        if block.contains(where: { $0.kind == .blockQuote }) {
            result.foregroundColor = .secondary
        }
        if let link = run.link, let scheme = link.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        {
            result.link = link
            result.foregroundColor = .accentColor
            result.underlineStyle = .single
        }
        return result
    }
}
