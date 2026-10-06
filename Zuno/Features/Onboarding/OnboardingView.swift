import SwiftUI

/// Minimal three-page onboarding. No permission is requested here; each permission is
/// explained and requested later, at the moment it becomes useful.
struct OnboardingView: View {
    struct Page: Identifiable {
        let id: Int
        let image: String
        let symbol: String
        let title: LocalizedStringKey
        let message: LocalizedStringKey
    }

    private let pages: [Page] = [
        Page(id: 0, image: "Onboarding1", symbol: "sparkles", title: "Discover what's on",
             message: "Hackathons, workshops, university meetups, exhibitions and cultural evenings across Sri Lanka — in one calm feed."),
        Page(id: 1, image: "Onboarding2", symbol: "ticket", title: "Register in seconds",
             message: "Fifteen free registrations every month, secure PayHere checkout for paid events, and QR tickets that work offline."),
        Page(id: 2, image: "Onboarding3", symbol: "lock.shield", title: "Private by design",
             message: "We never store your NIC number, payments are verified by our server, and you control location, notifications and Face ID."),
    ]

    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ZunoWordmark(size: 28)
                Spacer()
                if index < pages.count - 1 {
                    Button("Skip") { session.completeOnboarding(browseAsGuest: false) }
                        .font(.body.weight(.medium))
                        .foregroundStyle(.zunoSecondary)
                        .accessibilityIdentifier("onboarding.skip")
                }
            }
            .padding(.horizontal, ZunoMetrics.margin)
            .frame(minHeight: 50)

            TabView(selection: $index) {
                ForEach(pages) { page in
                    pageView(page).tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(pages) { page in
                    Capsule()
                        .fill(page.id == index ? ZunoColor.selectedFill : ZunoColor.textTertiary)
                        .frame(width: page.id == index ? 22 : 7, height: 7)
                }
            }
            .animation(ZunoMotion.adaptive(ZunoMotion.selection, reduceMotion: reduceMotion), value: index)
            .accessibilityElement()
            .accessibilityLabel(Text("Page \(index + 1) of \(pages.count)"))
            .padding(.bottom, 18)

            VStack(spacing: 10) {
                Button {
                    if index < pages.count - 1 {
                        withAnimation(ZunoMotion.adaptive(.easeInOut, reduceMotion: reduceMotion)) { index += 1 }
                    } else {
                        session.completeOnboarding(browseAsGuest: false)
                    }
                } label: {
                    Text(index < pages.count - 1 ? "Continue" : "Get started")
                }
                .buttonStyle(PrimaryCapsuleButtonStyle())
                .accessibilityIdentifier("onboarding.continue")
                if index == pages.count - 1 {
                    Button("Explore events first") { session.completeOnboarding(browseAsGuest: true) }
                        .font(.body.weight(.medium))
                        .foregroundStyle(.zunoSecondary)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("onboarding.explore")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .readableWidth(520)
        }
        .background(ZunoColor.background.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: index)
        .zunoContainer("onboarding.view")
    }

    private func pageView(_ page: Page) -> some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 18) {
                ArtworkImage(reference: .bundled(name: page.image))
                    .frame(height: min(proxy.size.height * 0.58, 520))
                    .clipShape(RoundedRectangle(cornerRadius: ZunoMetrics.detailArtworkRadius, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Image(systemName: page.symbol)
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.white)
                            .frame(width: 50, height: 50)
                            .zunoGlass(in: .circle, placement: .onMedia, interactive: false)
                            .padding(14)
                            .accessibilityHidden(true)
                    }
                Text(page.title)
                    .zunoDisplay(.detailTitle)
                    .foregroundStyle(.zunoPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(page.message)
                    .font(.body)
                    .foregroundStyle(.zunoSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ZunoMetrics.margin)
            .padding(.top, 8)
            .readableWidth(560)
        }
    }
}
