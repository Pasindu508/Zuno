import SwiftUI

/// "Location / ◉ Colombo, Sri Lanka" centered, with the circular notification control.
struct LocationHeader: View {
    let city: String
    let unreadCount: Int
    let onLocationTap: () -> Void
    let onNotificationsTap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            Button(action: onLocationTap) {
                VStack(spacing: 3) {
                    Text("Location")
                        .font(.footnote)
                        .foregroundStyle(.zunoSecondary)
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(ZunoColor.background, ZunoColor.amber)
                            .font(.system(size: 18))
                            .accessibilityHidden(true)
                        Text(verbatim: "\(city), \(String(localized: "Sri Lanka"))")
                            .font(.body)
                            .foregroundStyle(.zunoPrimary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(minHeight: ZunoMetrics.minimumTouchTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 64)
            .accessibilityLabel(Text("Location: \(city). Change location"))
            .accessibilityIdentifier("home.location")

            HStack {
                Spacer()
                NotificationButton(unreadCount: unreadCount, action: onNotificationsTap)
            }
        }
    }
}

struct NotificationButton: View {
    let unreadCount: Int
    let action: () -> Void

    var body: some View {
        FloatingGlassIconButton(
            systemName: "bell",
            accessibilityLabel: unreadCount > 0 ? Text("Notifications, \(unreadCount) unread") : Text("Notifications"),
            accessibilityIdentifier: "home.notifications",
            action: action
        )
        .symbolEffect(.bounce, value: unreadCount)
        .overlay(alignment: .topTrailing) {
            if unreadCount > 0 {
                Circle()
                    .fill(ZunoColor.amber)
                    .frame(width: 9, height: 9)
                    .offset(x: -14, y: 13)
                    .accessibilityHidden(true)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

/// Search capsule + filter control in one glass container. When active, the filter
/// control morphs into a close control and the field takes the focus.
struct HomeSearchBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isActive: Bool
    let activeFilterCount: Int
    let onFilter: () -> Void
    let onCancel: () -> Void

    @Namespace private var glassNamespace
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = ZunoMetrics.controlHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: ZunoMetrics.controlSpacing) {
            HStack(spacing: ZunoMetrics.controlSpacing) {
                field
                    .glassEffectID("search", in: glassNamespace)
                if isActive {
                    FloatingGlassIconButton(systemName: "xmark", accessibilityLabel: Text("Close search"),
                                            accessibilityIdentifier: "search.close", action: onCancel)
                        .glassEffectID("close", in: glassNamespace)
                } else {
                    filterButton
                        .glassEffectID("filter", in: glassNamespace)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isActive)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.zunoSecondary)
                .accessibilityHidden(true)
            TextField(text: $text, prompt: Text("Search any event…").foregroundStyle(ZunoColor.textTertiary)) {
                Text("Search events")
            }
            .font(.body)
            .foregroundStyle(.zunoPrimary)
            .focused(isFocused)
            .submitLabel(.search)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .accessibilityIdentifier("search.field")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.zunoTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search text"))
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: min(height, 72))
        .contentShape(.capsule)
        .zunoGlass(in: .capsule)
        .onTapGesture { isFocused.wrappedValue = true }
    }

    private var filterButton: some View {
        FloatingGlassIconButton(
            systemName: "slider.horizontal.3",
            accessibilityLabel: activeFilterCount > 0 ? Text("Filters, \(activeFilterCount) active") : Text("Filters"),
            accessibilityIdentifier: "home.filters",
            action: onFilter
        )
        .overlay(alignment: .topTrailing) {
            if activeFilterCount > 0 {
                Text(verbatim: "\(activeFilterCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ZunoColor.background)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(ZunoColor.amber))
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct CategoryOption: Identifiable, Hashable {
    let id: String
    let title: String
    let symbolName: String

    static let forYouID = "for-you"
    static let forYou = CategoryOption(id: forYouID, title: String(localized: "For you"), symbolName: "sparkles")

    init(id: String, title: String, symbolName: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
    }

    init(_ category: EventCategory) {
        self.init(id: category.id, title: category.name, symbolName: category.symbolName)
    }
}

/// Horizontally scrolling category capsules; the white selection fill glides between them.
struct CategoryBar: View {
    let options: [CategoryOption]
    @Binding var selection: String
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: ZunoMetrics.controlSpacing) {
                    ForEach(options) { option in
                        CategoryCapsule(option: option, isSelected: option.id == selection, namespace: selectionNamespace) {
                            withAnimation(ZunoMotion.adaptive(ZunoMotion.selection, reduceMotion: reduceMotion)) {
                                selection = option.id
                            }
                            withAnimation(ZunoMotion.adaptive(.easeOut(duration: 0.3), reduceMotion: reduceMotion)) {
                                proxy.scrollTo(option.id, anchor: .center)
                            }
                        }
                        .id(option.id)
                    }
                }
                .padding(.horizontal, ZunoMetrics.margin)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Categories"))
    }
}

struct CategoryCapsule: View {
    let option: CategoryOption
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = ZunoMetrics.controlHeight

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: option.symbolName)
                    .font(.system(size: 19, weight: .light))
                    .accessibilityHidden(true)
                Text(option.title)
                    .font(.body)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(isSelected ? ZunoColor.onSelectedFill : ZunoColor.textPrimary)
            .padding(.leading, 17)
            .padding(.trailing, 20)
            .frame(minHeight: min(height, 72))
            .background {
                if isSelected {
                    Capsule().fill(ZunoColor.selectedFill)
                        .matchedGeometryEffect(id: "category.selection", in: namespace)
                } else {
                    Capsule().fill(ZunoColor.surface)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("category.\(option.id)")
    }
}
