import SwiftUI

struct MarkdownTable {
    let rows: [[AttributedString]]
    let columns: [PresentationIntent.TableColumn]

    @MainActor
    func inlineAttachment() -> AttributedString {
        MarkdownTableAttachment(table: self).attributedText
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            ForEach(table.rows.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(table.columns.indices, id: \.self) { column in
                        let alignment = alignment(for: table.columns[column])
                        Text(table.rows[row][column])
                            .font(row == 0 ? .body.bold() : .body)
                            .multilineTextAlignment(alignment.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: alignment.view)
                    }
                }
                .anchorPreference(key: RowBounds.self, value: .bounds) { [$0] }
            }
        }
        .background(.background)
        .overlayPreferenceValue(RowBounds.self) { bounds in
            GeometryReader { geometry in
                let pixel = 1 / displayScale
                let outer = CGRect(origin: .zero, size: geometry.size)
                    .insetBy(dx: pixel / 2, dy: pixel / 2)
                Path { path in
                    path.addRect(outer)
                    for row in bounds.dropLast() {
                        let y = geometry[row].maxY
                        path.move(to: CGPoint(x: outer.minX, y: y))
                        path.addLine(to: CGPoint(x: outer.maxX, y: y))
                    }
                    for column in table.columns.indices.dropFirst() {
                        let x = geometry.size.width * CGFloat(column) / CGFloat(table.columns.count)
                        path.move(to: CGPoint(x: x, y: outer.minY))
                        path.addLine(to: CGPoint(x: x, y: outer.maxY))
                    }
                }
                .stroke(.secondary, lineWidth: pixel)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func alignment(
        for column: PresentationIntent.TableColumn
    ) -> (text: TextAlignment, view: Alignment) {
        switch column.alignment {
        case .left: (.leading, .leading)
        case .center: (.center, .center)
        case .right: (.trailing, .trailing)
        @unknown default: (.leading, .leading)
        }
    }

    private struct RowBounds: PreferenceKey {
        static let defaultValue: [Anchor<CGRect>] = []

        static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
            value += nextValue()
        }
    }
}

final class MarkdownTableAttachment: MarkdownViewAttachment {
    let table: MarkdownTable

    init(table: MarkdownTable) {
        self.table = table
        super.init(content: AnyView(MarkdownTableView(table: table)))
    }

    required init?(coder: NSCoder) {
        return nil
    }
}
