import SwiftUI

/// Event artwork with caching, cancellation, a dark shimmer placeholder, retry and a
/// failed-image fallback. Always aspect-fills and crops to its frame.
struct ArtworkImage: View {
    let reference: ImageReference?
    var accessibilityLabel: String?
    var fallbackSymbol = "photo.artframe"
    /// Subtle scale-settle when the image first appears (detail artwork).
    var settles = false

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    @State private var settled = false

    var body: some View {
        GeometryReader { proxy in
            let maxPixel = max(proxy.size.width, proxy.size.height) * displayScale
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(settles && !settled && !reduceMotion ? 1.045 : 1)
                        .clipped()
                        .transition(.opacity)
                } else if failed {
                    fallback
                } else {
                    ShimmerPlaceholder()
                }
            }
            .task(id: TaskKey(reference: reference, attempt: attempt, bucket: Int(maxPixel / 200))) {
                await load(maxPixel: maxPixel)
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel ?? ""))
        .accessibilityHidden(accessibilityLabel == nil)
        .accessibilityAddTraits(.isImage)
    }

    private struct TaskKey: Hashable {
        let reference: ImageReference?
        let attempt: Int
        let bucket: Int
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [ZunoColor.surfaceRaised, ZunoColor.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.zunoTertiary)
                if reference != nil {
                    Button {
                        failed = false
                        attempt += 1
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.zunoSecondary)
                    .accessibilityLabel(Text("Retry loading image"))
                }
            }
        }
    }

    private func load(maxPixel: CGFloat) async {
        guard let reference, maxPixel > 0 else {
            failed = reference == nil
            return
        }
        if let cached = ImagePipeline.shared.cachedImage(for: reference, maxPixelSize: maxPixel) {
            image = cached
            settle()
            return
        }
        do {
            let loaded = try await ImagePipeline.shared.image(for: reference, maxPixelSize: maxPixel)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            settle()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    private func settle() {
        guard settles, !settled else { return }
        withAnimation(ZunoMotion.settle) { settled = true }
    }
}

/// Subtle dark shimmer for loading placeholders; static under Reduce Motion.
struct ShimmerPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ZunoColor.surface
                if !reduceMotion {
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.06), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: phase * proxy.size.width)
                }
            }
            .clipped()
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.4 }
        }
        .accessibilityHidden(true)
    }
}
