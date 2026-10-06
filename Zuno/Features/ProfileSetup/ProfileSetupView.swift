import PhotosUI
import SwiftUI

/// Shared profile form used for first-run setup and later editing.
struct ProfileForm: View {
    @Binding var draft: ProfileDraft
    @Binding var avatarImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        let currentAvatar = avatarImage
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 16) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    ZStack {
                        if let avatarImage = currentAvatar {
                            Image(uiImage: avatarImage).resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(.zunoSecondary)
                        }
                    }
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(ZunoColor.surface))
                    .clipShape(.circle)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ZunoColor.onSelectedFill)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(ZunoColor.selectedFill))
                    }
                }
                .accessibilityLabel(Text("Choose profile photo (optional)"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profile photo").font(.body.weight(.medium)).foregroundStyle(.zunoPrimary)
                    Text("Optional. Shown to organizers only on your ticket.").font(.footnote).foregroundStyle(.zunoSecondary)
                }
            }
            .onChange(of: pickerItem) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                    avatarImage = image
                }
            }

            field(Text("Display name")) {
                TextField("How should we call you?", text: $draft.displayName)
                    .textContentType(.name)
                    .accessibilityIdentifier("profile.name")
            }

            field(Text("City")) {
                Picker(selection: $draft.city) {
                    ForEach(SriLankaLocations.places) { place in
                        Text("\(place.city) — \(place.district)").tag(place.city)
                    }
                } label: { Text("City") }
                .pickerStyle(.menu)
                .tint(ZunoColor.textPrimary)
                .onChange(of: draft.city) { _, city in
                    draft.district = SriLankaLocations.place(named: city)?.district ?? city
                }
                .accessibilityIdentifier("profile.city")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Interests").font(.headline).foregroundStyle(.zunoPrimary)
                Text("We'll recommend these first. You can change them any time.").font(.footnote).foregroundStyle(.zunoSecondary)
                FlowLayout(spacing: 8) {
                    ForEach(EventCategory.defaults) { category in
                        SelectableChip(title: Text(category.name), systemImage: category.symbolName,
                                       isSelected: draft.preferredCategories.contains(category.id)) {
                            if draft.preferredCategories.contains(category.id) { draft.preferredCategories.remove(category.id) }
                            else { draft.preferredCategories.insert(category.id) }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Language").font(.headline).foregroundStyle(.zunoPrimary)
                HStack(spacing: 8) {
                    ForEach(AppLanguage.allCases) { language in
                        SelectableChip(title: Text(verbatim: language.nativeName), isSelected: draft.language == language) {
                            draft.language = language
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Accessibility at events").font(.headline).foregroundStyle(.zunoPrimary)
                Text("Optional. Shared with organizers only when you register, so they can prepare.")
                    .font(.footnote).foregroundStyle(.zunoSecondary)
                FlowLayout(spacing: 8) {
                    ForEach(AccessibilityNeed.allCases) { need in
                        SelectableChip(title: Text(need.title), systemImage: need.symbolName, isSelected: draft.accessibilityNeeds.contains(need)) {
                            if draft.accessibilityNeeds.contains(need) { draft.accessibilityNeeds.remove(need) }
                            else { draft.accessibilityNeeds.insert(need) }
                        }
                    }
                }
            }
        }
    }

    private func field<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title.font(.headline).foregroundStyle(.zunoPrimary)
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
        }
    }
}

struct ProfileSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @State private var draft = ProfileDraft()
    @State private var avatar: UIImage?
    @State private var saving = false
    @State private var error: String?
    @State private var errorTrigger = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set up your profile")
                        .zunoDisplay(.detailTitle)
                        .foregroundStyle(.zunoPrimary)
                    Text("A few details so Zuno can show events near you.")
                        .font(.body).foregroundStyle(.zunoSecondary)
                }
                ProfileForm(draft: $draft, avatarImage: $avatar)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(uiColor: .systemRed))
                }
            }
            .padding(.horizontal, ZunoMetrics.margin)
            .padding(.vertical, 20)
            .readableWidth()
        }
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                Button("Continue") { Task { await save() } }
                    .buttonStyle(PrimaryCapsuleButtonStyle(isLoading: saving))
                    .disabled(!draft.isValid || saving)
                    .accessibilityIdentifier("profile.continue")
            }
        }
        .background(ZunoColor.background.ignoresSafeArea())
        .sensoryFeedback(.error, trigger: errorTrigger)
        .onAppear {
            if let profile = session.profile { draft = ProfileDraft(profile: profile) }
            if draft.displayName.isEmpty { draft.displayName = session.user?.displayNameHint ?? "" }
        }
        .zunoContainer("profile.setup")
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if let avatar, let data = avatar.jpegData(compressionQuality: 0.8) {
                draft.avatarPath = try await environment.profiles.uploadAvatar(data)
            }
            let profile = try await environment.profiles.saveProfile(draft, markOnboardingComplete: true)
            session.profileUpdated(profile)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorTrigger += 1
        }
    }
}

struct EditProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProfileDraft()
    @State private var avatar: UIImage?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ProfileForm(draft: $draft, avatarImage: $avatar)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mobile number").font(.headline).foregroundStyle(.zunoPrimary)
                    TextField("077 123 4567", text: $draft.phone)
                        .keyboardType(.phonePad)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                    Text("Used for PayHere receipts.").font(.footnote).foregroundStyle(.zunoSecondary)
                }
                if let error { Text(error).foregroundStyle(Color(uiColor: .systemRed)) }
            }
            .padding(ZunoMetrics.margin)
            .readableWidth()
        }
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                Button("Save") {
                    Task {
                        saving = true
                        defer { saving = false }
                        do {
                            if let avatar, let data = avatar.jpegData(compressionQuality: 0.8) {
                                draft.avatarPath = try await environment.profiles.uploadAvatar(data)
                            }
                            session.profileUpdated(try await environment.profiles.saveProfile(draft, markOnboardingComplete: true))
                            dismiss()
                        } catch {
                            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(isLoading: saving))
                .disabled(!draft.isValid || saving)
            }
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Edit profile"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .onAppear { if let profile = session.profile { draft = ProfileDraft(profile: profile) } }
    }
}
