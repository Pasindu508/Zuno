import SwiftUI

/// Shared empty / error / offline / loading states.
struct StateMessageView: View {
    let symbol: String
    let title: Text
    let message: Text
    var action: (title: Text, run: () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.zunoTertiary)
                .accessibilityHidden(true)
            title
                .font(.title3.weight(.semibold))
                .foregroundStyle(.zunoPrimary)
                .multilineTextAlignment(.center)
            message
                .font(.body)
                .foregroundStyle(.zunoSecondary)
                .multilineTextAlignment(.center)
            if let action {
                Button(action: action.run) { action.title }
                    .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
                    .frame(maxWidth: 260)
                    .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: Text
    let message: Text
    var actionTitle: Text?
    var action: (() -> Void)?

    var body: some View {
        StateMessageView(symbol: symbol, title: title, message: message,
                         action: actionTitle.flatMap { title in action.map { (title, $0) } })
            .zunoContainer("state.empty")
    }
}

struct ErrorStateView: View {
    let error: Error
    let retry: () -> Void

    var body: some View {
        let isOffline = (error as? ZunoError) == .offline
        StateMessageView(
            symbol: isOffline ? "wifi.slash" : "exclamationmark.triangle",
            title: isOffline ? Text("You're offline") : Text("Something went wrong"),
            message: Text((error as? LocalizedError)?.errorDescription ?? error.localizedDescription),
            action: (Text("Try again"), retry)
        )
        .zunoContainer("state.error")
    }
}

/// Thin banner shown at the top of content while offline.
struct OfflineBanner: View {
    var body: some View {
        Label("Offline — showing saved information", systemImage: "wifi.slash")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.zunoPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(ZunoColor.surface))
            .overlay(Capsule().strokeBorder(ZunoColor.amber.opacity(0.6), lineWidth: 1))
            .accessibilityIdentifier("state.offline")
    }
}

/// Skeleton matching the event card proportions.
struct EventCardSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ShimmerPlaceholder()
                .aspectRatio(ZunoMetrics.artworkAspectRatio, contentMode: .fit)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 6).fill(ZunoColor.surfaceRaised).frame(width: 220, height: 22)
                RoundedRectangle(cornerRadius: 5).fill(ZunoColor.surfaceRaised).frame(height: 14)
                RoundedRectangle(cornerRadius: 5).fill(ZunoColor.surfaceRaised).frame(width: 180, height: 14)
            }
            .padding(ZunoMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZunoColor.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct LoadingFeedView: View {
    var count = 2
    var body: some View {
        VStack(spacing: ZunoMetrics.cardSpacing) {
            ForEach(0..<count, id: \.self) { _ in EventCardSkeleton() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading events"))
        .accessibilityIdentifier("state.loading")
    }
}

/// Generic async content loader state.
enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(Error)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
