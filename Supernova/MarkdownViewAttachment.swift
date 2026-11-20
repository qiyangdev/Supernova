import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension AttributeScopes {
    struct ConversationFormatting: AttributeScope {
        let swiftUI: SwiftUIAttributes
        #if canImport(UIKit)
        let attachment: UIKitAttributes.AttachmentAttribute
        #elseif os(macOS)
        let attachment: AppKitAttributes.AttachmentAttribute
        #endif
    }
}

class MarkdownViewAttachment: NSTextAttachment {
    let content: AnyView
    let maximumWidth: CGFloat

    init(content: AnyView, maximumWidth: CGFloat = 640) {
        self.content = content
        self.maximumWidth = maximumWidth
        super.init(data: nil, ofType: nil)
    }

    var attributedText: AttributedString {
        AttributedString(NSAttributedString(attachment: self))
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var usesTextAttachmentView: Bool { true }

    #if canImport(UIKit)
    typealias ParentView = UIView
    #elseif os(macOS)
    typealias ParentView = NSView
    #endif

    override func viewProvider(
        for parentView: ParentView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        MarkdownAttachmentViewProvider(
            textAttachment: self, parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager, location: location
        )
    }
}

private final class MarkdownAttachmentViewProvider: NSTextAttachmentViewProvider {
    #if canImport(UIKit)
    private var host: UIHostingController<AnyView>?
    #elseif os(macOS)
    private var host: NSHostingController<AnyView>?
    #endif

    override init(
        textAttachment: NSTextAttachment,
        parentView: MarkdownViewAttachment.ParentView?,
        textLayoutManager: NSTextLayoutManager?,
        location: any NSTextLocation
    ) {
        super.init(
            textAttachment: textAttachment, parentView: parentView,
            textLayoutManager: textLayoutManager, location: location
        )
        tracksTextAttachmentViewBounds = true
    }

    override func loadView() {
        guard let attachment = textAttachment as? MarkdownViewAttachment else { return }
        #if canImport(UIKit)
        let host = UIHostingController(rootView: attachment.content)
        host.view.backgroundColor = .clear
        #elseif os(macOS)
        let host = NSHostingController(rootView: attachment.content)
        #endif
        self.host = host
        view = host.view
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        _ = view
        guard let host, let attachment = textAttachment as? MarkdownViewAttachment else { return .zero }
        let width = max(1, min(proposedLineFragment.width, attachment.maximumWidth))
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGRect(x: 0, y: 0, width: width, height: ceil(size.height))
    }
}
