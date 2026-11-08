import AuthenticationServices
import SwiftUI
#if canImport(GoogleSignInSwift)
import GoogleSignInSwift
#endif

/// Your avatar at the top right of Create opens this: just your profile.
struct ProfileView: View {
    @Environment(AccountService.self) private var account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AccountView(account: account, title: "Profile")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("profileDoneButton")
                    }
                }
        }
        .presentationDetents([.large])
    }
}

/// Your profile photo when there is one; otherwise an illustrated avatar picked from
/// your account (the same one every time), or from this iPhone when signed out.
struct ProfileAvatar: View {
    let user: AccountUser?
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let image = user?.image, let url = URL(string: image) {
                AsyncImage(url: url) { phase in
                    if let photo = phase.image { photo.resizable().scaledToFill() } else { illustrated }
                }
            } else {
                illustrated
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    /// Notionists avatars by Zoish (CC0 1.0), on RecordPOV lime.
    private var illustrated: some View {
        Image(Self.avatarName(seed: user?.id ?? Self.deviceSeed)).resizable().scaledToFill()
    }

    private static let avatarCount: UInt64 = 12
    private static let deviceSeed = UIDevice.current.identifierForVendor?.uuidString ?? "RecordPOV"

    /// A stable pick (FNV-1a), so the same account always gets the same avatar.
    private static func avatarName(seed: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "Avatar%02d", Int(hash % avatarCount) + 1)
    }
}

struct AccountView: View {
    /// Set when the editor asks for sign-in before saving.
    var onSignedIn: (() -> Void)?
    private let title: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var account: AccountService
    @State private var actionTask: Task<Void, Never>?
    @State private var confirmDeletion = false
    /// True while a sign-in, sign-out, deletion or retry started here is running.
    @State private var startedWork = false

    /// Profile and the editor pass the app's shared service, so a sign-in here counts everywhere.
    @MainActor init(account: AccountService? = nil, title: String = "Account", onSignedIn: (() -> Void)? = nil) {
        _account = State(initialValue: account ?? AccountService())
        self.title = title
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        Form {
            if let session = account.session {
                Section {
                    VStack(spacing: 8) {
                        ProfileAvatar(user: session.user, size: 84)
                        Text(session.user.name.isEmpty ? "Your account" : session.user.name)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        if !session.user.email.isEmpty {
                            Text(session.user.email).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("Signed in with \(session.provider.label)").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
                if account.needsReauthentication {
                    Section("Confirm account deletion") {
                        providerButtons
                        Button("Cancel deletion") { account.cancelPendingDeletion() }.disabled(account.isWorking)
                    }
                } else {
                    Section {
                        Button("Sign out") { run { await account.signOut() } }
                            .accessibilityIdentifier("accountSignOutButton")
                        Button("Delete account", role: .destructive) { confirmDeletion = true }
                            .accessibilityIdentifier("accountDeleteButton")
                    }.disabled(account.isWorking)
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            ProfileAvatar(user: nil, size: 52)
                            Text("Sign in to save your videos. Videos and drafts stay on this device.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 12) { providerButtons }
                        if account.hasLoaded, account.availableProviders.isEmpty, account.errorMessage == nil {
                            Text("Sign-in isn’t available yet. You can keep recording.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            if account.isWorking {
                Section { HStack(spacing: 10) { ProgressView(); Text("Please wait…").font(.subheadline) } }
            }
            if let message = account.statusMessage {
                Section { Text(message).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("accountStatusMessage") }
            }
            if let message = account.errorMessage {
                Section {
                    Text(message).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("accountErrorMessage")
                    if account.session == nil {
                        Button("Try again") { run { await account.load() } }.disabled(account.isWorking)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(RoastTheme.paper)
        .tint(RoastTheme.ink)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete your account?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { run { await account.deleteAccount() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes your account. Videos and drafts on this device will stay.")
        }
        .task { await account.load() }
        .onChange(of: account.session?.user.id) { _, id in if id != nil { onSignedIn?() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !account.isWorking { run { await account.load() } }
        }
        // The service is shared app-wide: stop only work this screen started, and clear
        // this screen's messages so the next Profile opens fresh.
        .onDisappear {
            actionTask?.cancel()
            if startedWork { account.cancel() }
            account.cancelPendingDeletion()
        }
    }

    @ViewBuilder private var providerButtons: some View {
        ForEach(account.availableProviders, id: \.self) { provider in
            switch provider {
            case .apple:
                NativeAppleAccountButton(isEnabled: !account.isWorking) { run { await account.signIn(with: .apple) } }
                    .frame(height: 48)
                    .accessibilityIdentifier("accountAppleSignInButton")
            case .google:
                #if canImport(GoogleSignInSwift)
                GoogleSignInButton(scheme: .light, style: .wide) { run { await account.signIn(with: .google) } }
                    .frame(height: 48).disabled(account.isWorking)
                    .accessibilityIdentifier("accountGoogleSignInButton")
                #endif
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        actionTask?.cancel()
        startedWork = true
        actionTask = Task { await operation(); startedWork = false }
    }
}

private struct NativeAppleAccountButton: UIViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .continue, authorizationButtonStyle: .black)
        button.cornerRadius = 10
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) { button.isEnabled = isEnabled }
}
