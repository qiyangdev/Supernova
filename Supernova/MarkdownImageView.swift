import SwiftUI
import Observation

#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct MarkdownImage: Hashable {
    let url: URL
    let alternativeText: String

    init?(url: URL, alternativeText: String) {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return nil
        }
        self.url = url
        self.alternativeText = alternativeText
    }
}

final class MarkdownImageAttachment: MarkdownViewAttachment {
    let markdownImage: MarkdownImage

    @MainActor
    init(image: MarkdownImage) {
        markdownImage = image
        let loader = MarkdownImageLoader(url: image.url)
        super.init(
            content: AnyView(MarkdownImageView(image: image, loader: loader)),
            maximumWidth: 416
        )
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

private struct MarkdownImageView: View {
    let image: MarkdownImage
    let loader: MarkdownImageLoader

    @Environment(\.displayScale) private var displayScale
    private let cornerRadius: CGFloat = 10

    private var imageLabel: Text {
        if image.alternativeText.isEmpty {
            Text("Image")
        } else {
            Text(verbatim: image.alternativeText)
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.quaternary)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                switch loader.phase {
                case .empty:
                    ProgressView()
                        .accessibilityLabel("Loading image")
                case .success(let loadedImage):
                    loadedImage.resizable()
                        .scaledToFill()
                        .accessibilityLabel(imageLabel)
                case .failure:
                    VStack(spacing: 6) {
                        Label("Image unavailable", systemImage: "photo")
                        if !image.alternativeText.isEmpty {
                            imageLabel
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(12)
                @unknown default:
                    imageLabel
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.secondary.opacity(0.35), lineWidth: 1 / displayScale)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onAppear { loader.loadIfNeeded() }
    }
}

@MainActor
@Observable
final class MarkdownImageLoader {
    typealias FetchImage = @MainActor (URL) async throws -> Image

    private(set) var phase: AsyncImagePhase = .empty
    private let url: URL
    private let fetch: FetchImage
    @ObservationIgnored private var request: Task<Void, Never>?

    init(url: URL, fetch: @escaping FetchImage = MarkdownImageLoader.download) {
        self.url = url
        self.fetch = fetch
    }

    deinit {
        request?.cancel()
    }

    @discardableResult
    func loadIfNeeded() -> Task<Void, Never>? {
        if let request { return request }
        guard case .empty = phase else { return nil }

        // The attachment keeps this task alive when TextKit replaces its hosted view.
        let request = Task { [weak self, fetch, url] in
            let phase: AsyncImagePhase
            do {
                phase = .success(try await fetch(url))
            } catch {
                phase = .failure(error)
            }
            self?.phase = phase
            self?.request = nil
        }
        self.request = request
        return request
    }

    private static func download(_ url: URL) async throws -> Image {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else { throw URLError(.badServerResponse) }

        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        return Image(uiImage: image)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        return Image(nsImage: image)
        #endif
    }
}
