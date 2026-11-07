import AuthenticationServices
import SwiftUI
#if canImport(GoogleSignInSwift)
import GoogleSignInSwift
#endif

struct AccountView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var account = AccountService()
    @State private var actionTask: Task<Void, Never>?
    @State private var confirmDeletion = false

    var body: some View {
        Form {
            if let session = account.session {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.user.name.isEmpty ? "Your account" : session.user.name).font(.headline)
                        if !session.user.email.isEmpty { Text(session.user.email).font(.subheadline).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
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
                        Text("Sign-in is optional. Videos and drafts stay on this device.")
                            .font(.subheadline).foregroundStyle(.secondary)
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
        .navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete your account?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { run { await account.deleteAccount() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes your account. Videos and drafts on this device will stay.")
        }
        .task { await account.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !account.isWorking { run { await account.load() } }
        }
        .onDisappear { actionTask?.cancel(); account.cancel() }
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
        actionTask = Task { await operation() }
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
