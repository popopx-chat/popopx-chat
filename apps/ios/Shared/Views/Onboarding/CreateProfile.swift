//
//  CreateProfile.swift
//  POPOPX (iOS)
//
//  Created by Evgeny on 07/05/2022.
//  Copyright © 2022 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//
// Spec: spec/client/navigation.md

import SwiftUI
import POPOPXChat

enum UserProfileAlert: Identifiable {
    case duplicateUserError
    case invalidDisplayNameError
    case createUserError(error: LocalizedStringKey)
    case invalidNameError(validName: String)

    var id: String {
        switch self {
        case .duplicateUserError: return "duplicateUserError"
        case .invalidDisplayNameError: return "invalidDisplayNameError"
        case .createUserError: return "createUserError"
        case let .invalidNameError(validName): return "invalidNameError \(validName)"
        }
    }
}

let MAX_BIO_LENGTH_BYTES = 160

struct CreateProfile: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var theme: AppTheme
    @State private var displayName: String = ""
    @State private var profileBio: String = ""
    @FocusState private var focusDisplayName
    @State private var alert: UserProfileAlert?
    @State private var isCreatingProfile = false
    @State private var showChooseSource = false
    @State private var showImagePicker = false
    @State private var showTakePhoto = false
    @State private var chosenImage: UIImage? = nil
    @State private var profileImage: String? = nil

    var body: some View {
        List {
            Group {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .center) {
                        ZStack(alignment: .topTrailing) {
                            ProfileImage(imageStr: profileImage, size: 128)
                            if profileImage != nil {
                                Button {
                                    profileImage = nil
                                } label: {
                                    Image(systemName: "multiply")
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 12)
                                }
                            }
                        }

                        editImageButton { showChooseSource = true }
                            .buttonStyle(BorderlessButtonStyle())
                    }
                    .padding(.horizontal, 10) // Offsets transparent space built into 3D asset
                    Spacer(minLength: 0)
                    #if POPOPX_ASSETS || SIMPLEX_ASSETS
                    Image(colorScheme == .light ? "create-profile" : "create-profile-light")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 140)
                    // No trailing spacer — asset image has empty space on the right
                    #endif
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))

            Section {
                ZStack(alignment: .leading) {
                    let name = displayName.trimmingCharacters(in: .whitespaces)
                    if name != mkValidName(name) {
                        Button {
                            alert = .invalidNameError(validName: mkValidName(name))
                        } label: {
                            Image(systemName: "exclamationmark.circle").foregroundColor(.red)
                        }
                    } else {
                        Image(systemName: "pencil").foregroundColor(theme.colors.secondary)
                    }
                    TextField("Enter your name…", text: $displayName)
                        .padding(.leading, 36)
                        .focused($focusDisplayName)
                }
                ZStack(alignment: .leading) {
                    Image(systemName: "pencil").foregroundColor(theme.colors.secondary)
                    TextField("Bio", text: $profileBio)
                        .padding(.leading, 36)
                }
                Button {
                    Task { await createProfile() }
                } label: {
                    settingsRow("checkmark", color: theme.colors.primary) { Text("Create profile") }
                }
                .disabled(!canCreateProfile(displayName) || !bioFitsLimit() || isCreatingProfile)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your profile is stored on your device and only shared with your contacts.")
                }
                .foregroundColor(theme.colors.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .compactSectionSpacing()
        }
        .navigationTitle("Create your profile")
        .modifier(ThemedBackground(grouped: true))
        .alert(item: $alert) { a in userProfileAlert(a, $displayName) }
        .confirmationDialog("Profile image", isPresented: $showChooseSource, titleVisibility: .visible) {
            Button("Take picture") {
                showTakePhoto = true
            }
            Button("Choose from library") {
                showImagePicker = true
            }
        }
        .fullScreenCover(isPresented: $showTakePhoto) {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                CameraImagePicker(image: $chosenImage)
            }
        }
        .sheet(isPresented: $showImagePicker) {
            LibraryImagePicker(image: $chosenImage) { _ in
                await MainActor.run {
                    showImagePicker = false
                }
            }
        }
        .onChange(of: chosenImage) { _, image in
            Task {
                let resized: String? = if let image {
                    await resizeImageToStrSize(cropToSquare(image), maxDataSize: 12500)
                } else {
                    nil
                }
                await MainActor.run { profileImage = resized }
            }
        }
        .onAppear() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                focusDisplayName = true
            }
        }
    }

    private func bioFitsLimit() -> Bool {
        chatJsonLength(profileBio) <= MAX_BIO_LENGTH_BYTES
    }

    // A-1 (device 0x8BADF00D watchdog): `chatSendCmdSync` is a synchronous FFI, and when the server does not answer the main thread hangs the whole time,
    // until the system declares the process unresponsive and kills it. Here only the two calls that "take the return value" are moved to the background,
    // while `startChat` / `getUserChatData` publish ChatModel, ChatTagsModel and NtfManager state and must stay on the main thread,
    // so the whole function is marked `@MainActor`: the resumed continuation always returns to the main thread, so no model is ever mutated in the background.
    @MainActor
    private func createProfile() async {
        guard !isCreatingProfile else { return }
        isCreatingProfile = true
        defer { isCreatingProfile = false }
        hideKeyboard()
        let shortDescr: String? = if profileBio.isEmpty { nil } else { profileBio }
        let profile = Profile(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            fullName: "",
            shortDescr: shortDescr,
            image: profileImage
        )
        let m = ChatModel.shared
        do {
            AppChatState.shared.set(.active)
            let created = await Task.detached(priority: .userInitiated) { () -> Result<User, Error> in
                Result { try apiCreateActiveUser(profile) }
            }.value
            m.currentUser = try created.get()
            // .isEmpty check is redundant here, but it makes it clearer what is going on
            if m.users.isEmpty || m.users.allSatisfy({ $0.user.hidden }) {
                try startChat()
                withAnimation {
                    onboardingStageDefault.set(.step3_ChooseServerOperators)
                    m.onboardingStage = .step3_ChooseServerOperators
                }
            } else {
                onboardingStageDefault.set(.onboardingComplete)
                m.onboardingStage = .onboardingComplete
                dismiss()
                let users = await Task.detached(priority: .userInitiated) { () -> Result<[UserInfo], Error> in
                    Result { try listUsers() }
                }.value
                m.users = try users.get()
                try getUserChatData()
            }
        } catch let error {
            showCreateProfileAlert(showAlert: { alert = $0 }, error)
        }
    }
}

struct CreateFirstProfile: View {
    @EnvironmentObject var m: ChatModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(GROUP_DEFAULT_INCOGNITO, store: groupDefaults) private var incognitoDefault = false

    @State private var displayName: String = ""
    @State private var note: String = ""
    @State private var profileImage: String? = nil
    @State private var chosenImage: UIImage? = nil
    @State private var avatarTintIndex = 0
    @State private var showChooseSource = false
    @State private var showImagePicker = false
    @State private var showTakePhoto = false
    @State private var nextStepNavLinkActive = false
    @State private var showMigrateSheet = false
    @State private var isCreatingProfile = false

    // Onboarding screen 2: create the first anonymous identity.
    private static let avatarSize: CGFloat = 112
    private static let avatarTints: [Color] = [
        PopopxPalette.brand,
        PopopxPalette.mesh,
        PopopxPalette.success,
        PopopxPalette.danger,
        PopopxPalette.labelSecondary
    ]

    var body: some View {
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: PopopxMetrics.spaceL) {
                    PopopxOnboardingHeader(
                        step: 1,
                        steps: 3,
                        stage: PopopxOnboardingCopy.stageIdentity,
                        title: PopopxOnboardingCopy.identityTitle,
                        note: PopopxOnboardingCopy.identityNote
                    )
                    .padding(.horizontal, PopopxMetrics.gutter)

                    avatarRow
                        .padding(.horizontal, PopopxMetrics.gutter)

                    fieldsCard

                    privacyCard

                    nextButton
                        .padding(.horizontal, PopopxMetrics.gutter)
                        .padding(.top, PopopxMetrics.space2XS)
                }
                .padding(.top, PopopxMetrics.spaceM)
                .padding(.bottom, PopopxMetrics.space2XL)
                .frame(maxWidth: .infinity, minHeight: g.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onTapGesture { hideKeyboard() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if m.migrationState == nil {
                            m.migrationState = .pasteOrScanLink
                        }
                        showMigrateSheet = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down.fill")
                    }
                    .accessibilityLabel(Text(PopopxOnboardingCopy.restoreBackup))
                }
            }
            .sheet(isPresented: $showMigrateSheet, onDismiss: { m.migrationState = nil }) {
                NavigationStack {
                    MigrateToDevice(migrationState: $m.migrationState)
                        .navigationTitle("Migrate here")
                        .modifier(ThemedBackground(grouped: true))
                }
            }
        }
        .background(PopopxPalette.base, ignoresSafeAreaEdges: .all)
        .confirmationDialog(PopopxOnboardingCopy.profilePhoto, isPresented: $showChooseSource, titleVisibility: .visible) {
            Button("Take picture") {
                showTakePhoto = true
            }
            Button("Choose from library") {
                showImagePicker = true
            }
        }
        .fullScreenCover(isPresented: $showTakePhoto) {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                CameraImagePicker(image: $chosenImage)
            }
        }
        .sheet(isPresented: $showImagePicker) {
            LibraryImagePicker(image: $chosenImage) { _ in
                await MainActor.run {
                    showImagePicker = false
                }
            }
        }
        .onChange(of: chosenImage) { _, image in
            Task {
                let resized: String? = if let image {
                    await resizeImageToStrSize(cropToSquare(image), maxDataSize: 12500)
                } else {
                    nil
                }
                await MainActor.run { profileImage = resized }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Avatar

    private var avatarTint: Color { Self.avatarTints[avatarTintIndex % Self.avatarTints.count] }

    private var avatarRow: some View {
        HStack(alignment: .center, spacing: PopopxMetrics.spaceM) {
            Button {
                PopopxHaptics.impact(.light)
                showChooseSource = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    ProfileImage(
                        imageStr: profileImage,
                        size: Self.avatarSize,
                        color: avatarTint,
                        backgroundColor: avatarTint.opacity(0.16)
                    )
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                    .clipShape(Circle())

                    Image(systemName: "camera.fill")
                        .font(PopopxType.microTag)
                        .foregroundStyle(PopopxPalette.onBrand)
                        .frame(width: PopopxMetrics.spaceXL, height: PopopxMetrics.spaceXL)
                        .background(PopopxPalette.brand, in: Circle())
                        .overlay(Circle().strokeBorder(PopopxPalette.base, lineWidth: PopopxMetrics.divider))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(PopopxOnboardingCopy.profilePhoto))
            .accessibilityHint(Text(PopopxOnboardingCopy.tapToChoosePhoto))

            VStack(alignment: .leading, spacing: PopopxMetrics.spaceXS) {
                Text(PopopxOnboardingCopy.profilePhoto)
                    .font(PopopxType.emphasis)
                    .foregroundStyle(PopopxPalette.label)
                Text(PopopxOnboardingCopy.tapToChoosePhoto)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                PopopxButton(
                    PopopxOnboardingCopy.newAvatar,
                    systemImage: "paintpalette.fill",
                    role: .secondary,
                    fullWidth: false
                ) {
                    withAnimation(PopopxSpring.snappy) {
                        avatarTintIndex += 1
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Fields

    private var trimmedName: String { displayName.trimmingCharacters(in: .whitespaces) }

    private var suggestedName: String { mkValidName(trimmedName) }

    private var nameIsUsable: Bool { canCreateProfile(displayName) }

    private var noteFitsLimit: Bool { chatJsonLength(note) <= MAX_BIO_LENGTH_BYTES }

    private var fieldsCard: some View {
        PopopxSectionCard {
            PopopxTextField(
                PopopxOnboardingCopy.anonymousName,
                prompt: PopopxOnboardingCopy.anonymousNamePrompt,
                text: $displayName,
                systemImage: "person.crop.circle.badge.plus",
                onSubmit: { _ in hideKeyboard() }
            )

            if !trimmedName.isEmpty && trimmedName != suggestedName {
                HStack(alignment: .center, spacing: PopopxMetrics.spaceS) {
                    PopopxOnboardingIconBadge(systemName: "exclamationmark.circle.fill", tint: .danger)
                    Text(PopopxOnboardingCopy.nameInvalidHint)
                        .font(PopopxType.caption)
                        .foregroundStyle(PopopxPalette.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            } else if trimmedName.isEmpty {
                Text(PopopxOnboardingCopy.nameRequired)
                    .font(PopopxType.caption)
                    .foregroundStyle(PopopxPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PopopxOnboardingHairline()

            PopopxTextField(
                PopopxOnboardingCopy.noteForFriends,
                prompt: PopopxOnboardingCopy.noteForFriendsPrompt,
                text: $note,
                systemImage: "text.alignleft",
                onSubmit: { _ in hideKeyboard() }
            )

            if !note.isEmpty {
                HStack(alignment: .center, spacing: PopopxMetrics.spaceXS) {
                    Spacer(minLength: 0)
                    Text(verbatim: "\(chatJsonLength(note)) / \(MAX_BIO_LENGTH_BYTES)")
                        .font(PopopxType.metricSmall)
                        .foregroundStyle(noteFitsLimit ? PopopxPalette.labelHint : PopopxPalette.dangerInk)
                }
            }
        }
        .popopxAnimation(PopopxSpring.snappy, value: trimmedName, reduceMotion: reduceMotion)
    }

    private var privacyCard: some View {
        PopopxSectionCard(PopopxOnboardingCopy.privacyBoost) {
            PopopxToggleRow(
                PopopxOnboardingCopy.incognitoRow,
                note: PopopxOnboardingCopy.incognitoNote,
                systemImage: "person.crop.circle.badge.questionmark",
                tint: .brand,
                isOn: $incognitoDefault
            )
        }
    }

    // MARK: - Next step

    private var nextButton: some View {
        PopopxButton(PopopxOnboardingCopy.next, systemImage: "arrow.right", isLoading: isCreatingProfile) {
            await createProfile()
        }
        .disabled(!nameIsUsable || !noteFitsLimit || isCreatingProfile)
        .navigationDestination(isPresented: $nextStepNavLinkActive) {
            nextStepDestinationView()
        }
    }

    private func showAlert(_ alert: UserProfileAlert) {
        AlertManager.shared.showAlert(userProfileAlert(alert, $displayName))
    }

    private func nextStepDestinationView() -> some View {
        YourNetworkView()
            .navigationBarBackButtonHidden(true)
            .modifier(ThemedBackground())
    }

    // A-1 (device 0x8BADF00D watchdog): `apiCreateActiveUser` goes through synchronous FFI, and when the server does not answer the main thread hangs the whole time,
    // and the system declares it unresponsive and kills the process outright — the crash when tapping "Next" on onboarding screen 2 was exactly this. Here only the one call that takes the return value
    // is put on a background queue, while `startChat(onboarding:)` writes ChatModel / NtfManager and drives animations, so it must stay on the main thread;
    // the function is marked `@MainActor`, so the continuation always returns to the main thread and "mutating models in the background" cannot happen.
    @MainActor
    private func createProfile() async {
        guard !isCreatingProfile else { return }
        isCreatingProfile = true
        defer { isCreatingProfile = false }
        hideKeyboard()
        let profile = Profile(
            displayName: trimmedName,
            fullName: "",
            shortDescr: note.isEmpty ? nil : note,
            image: profileImage
        )
        let m = ChatModel.shared
        do {
            AppChatState.shared.set(.active)
            let created = await Task.detached(priority: .userInitiated) { () -> Result<User, Error> in
                Result { try apiCreateActiveUser(profile) }
            }.value
            m.currentUser = try created.get()
            // new users don't need the local file encryption indicator (all files are encrypted); existing users keep it on
            UserDefaults.standard.set(false, forKey: DEFAULT_PRIVACY_SHOW_FILE_ENCRYPTION)
            try startChat(onboarding: true)
            onboardingStageDefault.set(.step3_ChooseServerOperators)
            nextStepNavLinkActive = true
        } catch let error {
            showCreateProfileAlert(showAlert: showAlert, error)
        }
    }
}

private func showCreateProfileAlert(
    showAlert: (UserProfileAlert) -> Void,
    _ error: Error
) {
    let m = ChatModel.shared
    switch error as? ChatError {
    case .errorStore(.duplicateName),
         .error(.userExists):
        if m.currentUser == nil {
            AlertManager.shared.showAlert(duplicateUserAlert)
        } else {
            showAlert(.duplicateUserError)
        }
    case .error(.invalidDisplayName):
        if m.currentUser == nil {
            AlertManager.shared.showAlert(invalidDisplayNameAlert)
        } else {
            showAlert(.invalidDisplayNameError)
        }
    default:
        let err: LocalizedStringKey = "Error: \(responseError(error))"
        if m.currentUser == nil {
            AlertManager.shared.showAlert(creatUserErrorAlert(err))
        } else {
            showAlert(.createUserError(error: err))
        }
    }
    logger.error("Failed to create user or start chat: \(responseError(error))")
}

private func canCreateProfile(_ displayName: String) -> Bool {
    let name = displayName.trimmingCharacters(in: .whitespaces)
    return name != "" && mkValidName(name) == name
}

func userProfileAlert(_ alert: UserProfileAlert, _ displayName: Binding<String>) -> Alert {
    switch alert {
    case .duplicateUserError: return duplicateUserAlert
    case .invalidDisplayNameError: return invalidDisplayNameAlert
    case let .createUserError(err): return creatUserErrorAlert(err)
    case let .invalidNameError(name): return createInvalidNameAlert(name, displayName)
    }
}

private var duplicateUserAlert: Alert {
    Alert(
        title: Text("Duplicate display name!"),
        message: Text("You already have a chat profile with the same display name. Please choose another name.")
    )
}

private var invalidDisplayNameAlert: Alert {
    Alert(
        title: Text("Invalid display name!"),
        message: Text("This display name is invalid. Please choose another name.")
    )
}

private func creatUserErrorAlert(_ err: LocalizedStringKey) -> Alert {
    Alert(
        title: Text("Error creating profile!"),
        message: Text(err)
    )
}

func createInvalidNameAlert(_ name: String, _ displayName: Binding<String>) -> Alert {
    name == ""
    ? Alert(title: Text("Invalid name!"))
    : Alert(
        title: Text("Invalid name!"),
        message: Text("Correct name to \(name)?"),
        primaryButton: .default(
            Text("Ok"),
            action: { displayName.wrappedValue = name }
        ),
        secondaryButton: .cancel()
    )
}

func validDisplayName(_ name: String) -> Bool {
    mkValidName(name.trimmingCharacters(in: .whitespaces)) == name
}

func mkValidName(_ s: String) -> String {
    var c = s.cString(using: .utf8)!
    return fromCString(chat_valid_name(&c)!)
}

struct CreateProfile_Previews: PreviewProvider {
    static var previews: some View {
        CreateProfile()
    }
}
