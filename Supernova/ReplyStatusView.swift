import SwiftUI
import ThinkingOrbs

struct ReplyStatusView: View {
    let status: ReplyStatus
    let isRetryDisabled: () -> Bool
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch status {
            case .stopped:
                Label("Stopped", systemImage: "stop.circle")
            case .interrupted:
                Label("Reply interrupted", systemImage: "exclamationmark.circle")
            case .failed:
                Label("Couldn’t get a reply", systemImage: "exclamationmark.circle")
            case .completed:
                EmptyView()
            }

            Button("Retry", systemImage: "arrow.clockwise", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRetryDisabled())
                .accessibilityIdentifier("retryReply")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RetryActivityView: View {
    var body: some View {
        ThinkingOrbLabel("Retrying…", design: .breathing, size: .small)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
