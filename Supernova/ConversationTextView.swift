import SwiftUI
import ThinkingOrbs

#if canImport(UIKit)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

@MainActor
final class ConversationTextView {
    private static var label: some View {
        ThinkingOrbLabel("Thinking…", design: .breathing, size: .small)
            .font(.callout)
            .fixedSize()
            .allowsHitTesting(false)
    }

    #if canImport(UIKit)
        typealias TextView = UITextView
        private let indicator: UIView = {
            let view = UIHostingConfiguration { ConversationTextView.label }
                .margins(.all, 0)
                .makeContentView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = true
            view.accessibilityLabel = String(localized: "Waiting for reply")
            view.accessibilityIdentifier = "replyLoadingIndicator"
            return view
        }()
    #elseif os(macOS)
        typealias TextView = NSTextView
        private let indicator: NSView = {
            let view = NSHostingView(rootView: ConversationTextView.label)
            view.setAccessibilityElement(true)
            view.setAccessibilityLabel(String(localized: "Waiting for reply"))
            return view
        }()
    #endif

    private weak var textView: TextView?
    private let editDelegate = DraftEditDelegate()
    private var isWaitingForReply = false
    private var isResponding = false

    func attach(to textView: TextView, draftStart: @escaping () -> Int) {
        self.textView = textView
        editDelegate.draftStart = draftStart
        if textView.delegate !== editDelegate {
            editDelegate.downstream = textView.delegate
            textView.delegate = editDelegate
        }
        textView.isEditable = !isResponding
        if isWaitingForReply { schedulePlacement() }
    }

    func setResponding(_ isResponding: Bool) {
        self.isResponding = isResponding
        textView?.isEditable = !isResponding
    }

    func followReply() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isResponding, let textView = self.textView,
                let end = self.endOfTextRect(in: textView)
            else { return }
            self.scroll(end, in: textView)
        }
    }

    func setWaitingForReply(_ isWaiting: Bool) {
        isWaitingForReply = isWaiting
        if isWaiting {
            schedulePlacement()
        } else {
            indicator.removeFromSuperview()
        }
    }

    private func schedulePlacement() {
        DispatchQueue.main.async { [weak self] in
            self?.placeAfterTextLayout()
        }
    }

    private func placeAfterTextLayout() {
        guard isWaitingForReply, let textView else { return }

        #if canImport(UIKit)
            guard textView.text.hasSuffix("\n\n") else { return }
        #elseif os(macOS)
            guard textView.string.hasSuffix("\n\n") else { return }
        #endif
        guard let caret = endOfTextRect(in: textView) else { return }

        let needsAttachment = indicator.superview !== textView
        if needsAttachment { textView.addSubview(indicator) }

        #if canImport(UIKit)
            let size = indicator.systemLayoutSizeFitting(
                UIView.layoutFittingCompressedSize
            )
        #elseif os(macOS)
            let size = indicator.fittingSize
        #endif
        indicator.frame = CGRect(
            origin: CGPoint(x: caret.minX, y: caret.midY - size.height / 2),
            size: size
        )

        guard needsAttachment else { return }
        scroll(indicator.frame, in: textView)
    }

    private func endOfTextRect(in textView: TextView) -> CGRect? {
        var rect: CGRect
        #if canImport(UIKit)
            textView.layoutIfNeeded()
            rect = textView.caretRect(for: textView.endOfDocument)
        #elseif os(macOS)
            guard let window = textView.window else { return nil }
            let end = NSRange(location: textView.string.utf16.count, length: 0)
            let screenRect = textView.firstRect(
                forCharacterRange: end,
                actualRange: nil
            )
            rect = textView.convert(
                window.convertFromScreen(screenRect),
                from: nil
            )
        #endif
        guard !rect.isNull, rect.height > 0 else { return nil }
        rect.size.width = max(rect.width, 1)
        return rect
    }

    private func scroll(_ rect: CGRect, in textView: TextView) {
        #if canImport(UIKit)
            textView.scrollRectToVisible(rect, animated: false)
        #elseif os(macOS)
            textView.scrollToVisible(rect)
        #endif
    }
}

#if canImport(UIKit)
    private typealias TextViewDelegate = UITextViewDelegate
#elseif os(macOS)
    private typealias TextViewDelegate = NSTextViewDelegate
#endif

@MainActor
private final class DraftEditDelegate: NSObject, TextViewDelegate {
    // NSObject queries Objective-C selectors outside the actor-isolated delegate API.
    nonisolated(unsafe) weak var downstream: (any TextViewDelegate)?
    var draftStart: () -> Int = { 0 }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector)
            || downstream?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any?
    {
        if downstream?.responds(to: selector) == true { return downstream }
        return super.forwardingTarget(for: selector)
    }

    #if canImport(UIKit)
        func textView(
            _ textView: UITextView,
            shouldChangeTextInRanges ranges: [NSValue],
            replacementText text: String
        ) -> Bool {
            let start = draftStart()
            guard ranges.allSatisfy({ $0.rangeValue.location >= start }) else {
                return false
            }
            if let allowed = downstream?.textView?(
                textView,
                shouldChangeTextInRanges: ranges,
                replacementText: text
            ) {
                return allowed
            }
            guard let first = ranges.first?.rangeValue else { return true }
            let union = ranges.dropFirst().reduce(first) {
                NSUnionRange($0, $1.rangeValue)
            }
            return downstream?.textView?(
                textView,
                shouldChangeTextIn: union,
                replacementText: text
            ) ?? true
        }
    #elseif os(macOS)
        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges ranges: [NSValue],
            replacementStrings strings: [String]?
        ) -> Bool {
            let start = draftStart()
            guard ranges.allSatisfy({ $0.rangeValue.location >= start }) else {
                return false
            }
            if let allowed = downstream?.textView?(
                textView,
                shouldChangeTextInRanges: ranges,
                replacementStrings: strings
            ) {
                return allowed
            }
            return ranges.enumerated().allSatisfy { index, range in
                downstream?.textView?(
                    textView,
                    shouldChangeTextIn: range.rangeValue,
                    replacementString: strings?[index]
                ) ?? true
            }
        }
    #endif
}
