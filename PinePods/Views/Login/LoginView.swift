import SwiftUI

struct LoginView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library

    @State private var serverUrl = "https://"
    @State private var username = ""
    @State private var password = ""
    @State private var mfaCode = ""
    @State private var mfaSessionToken: String?
    @State private var isLoggingIn = false
    @State private var errorMessage: String?
    @State private var appeared = false

    @FocusState private var focus: Field?

    private enum Field: Hashable { case server, username, password, mfa }

    var body: some View {
        ZStack {
            LoginBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 48)

                    brand
                        .scaleEffect(appeared ? 1 : 0.85)
                        .opacity(appeared ? 1 : 0)

                    form
                        .offset(y: appeared ? 0 : 24)
                        .opacity(appeared ? 1 : 0)

                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.25)) { appeared = true }
        }
    }

    private var brand: some View {
        VStack(spacing: 14) {
            Image(.brandMark)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(14)
                .frame(width: 96, height: 96)
                .glassEffect(.regular.tint(PineGreen.opacity(0.5)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Kural")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("குரல்")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Kural")
                Text("Your podcasts, from your own PinePods server.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var form: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                field("Server URL", text: $serverUrl, icon: "server.rack", field: .server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .submitLabel(.next)
                field("Username", text: $username, icon: "person.fill", field: .username)
                    .textContentType(.username)
                    .submitLabel(.next)
                field("Password", text: $password, icon: "lock.fill", field: .password, isSecure: true)
                    .textContentType(.password)
                    .submitLabel(mfaSessionToken == nil ? .go : .next)
                if mfaSessionToken != nil {
                    field("6-digit code", text: $mfaCode, icon: "key.fill", field: .mfa)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onSubmit(advanceFocus)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            Button {
                Task { await submit() }
            } label: {
                Group {
                    if isLoggingIn {
                        ProgressView()
                    } else {
                        Text(mfaSessionToken == nil ? "Sign In" : "Verify & Sign In")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(PineGreen)
            .controlSize(.large)
            .disabled(!canSubmit || isLoggingIn)
            .padding(.top, 4)

            if mfaSessionToken != nil {
                Button("Use a different account") {
                    withAnimation {
                        mfaSessionToken = nil
                        mfaCode = ""
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .animation(.snappy, value: mfaSessionToken)
        .animation(.snappy, value: errorMessage)
    }

    private var canSubmit: Bool {
        let base = !serverUrl.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.isEmpty
            && !password.isEmpty
        if mfaSessionToken != nil {
            return base && !mfaCode.isEmpty
        }
        return base
    }

    private func field(
        _ label: String, text: Binding<String>, icon: String, field: Field, isSecure: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(focus == field ? PineGreen : .white.opacity(0.55))
                .frame(width: 22)
            Group {
                if isSecure {
                    SecureField(label, text: text)
                } else {
                    TextField(label, text: text)
                }
            }
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: field)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white.opacity(focus == field ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focus == field ? PineGreen.opacity(0.8) : .white.opacity(0.1), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.15), value: focus)
    }

    private func advanceFocus() {
        switch focus {
        case .server: focus = .username
        case .username: focus = .password
        case .password:
            if mfaSessionToken != nil {
                focus = .mfa
            } else if canSubmit {
                Task { await submit() }
            }
        case .mfa:
            if canSubmit { Task { await submit() } }
        case nil: break
        }
    }

    private func submit() async {
        isLoggingIn = true
        errorMessage = nil
        defer { isLoggingIn = false }

        let trimmedServer = APIClient.normalizeServer(serverUrl)

        do {
            if let mfaSessionToken {
                let apiKey = try await APIClient.verifyMfa(
                    serverUrl: trimmedServer, sessionToken: mfaSessionToken, code: mfaCode)
                try await session.establish(
                    serverUrl: trimmedServer, username: username, apiKey: apiKey)
                mfaCode = ""
                self.mfaSessionToken = nil
                await finishLogin()
                return
            }

            let isPinepods = await APIClient.verifyInstance(trimmedServer)
            guard isPinepods else {
                errorMessage = "That URL doesn't look like a PinePods server (checked /api/pinepods_check)."
                return
            }

            switch try await APIClient.startLogin(
                serverUrl: trimmedServer, username: username, password: password) {
            case .authenticated(let apiKey):
                try await session.establish(
                    serverUrl: trimmedServer, username: username, apiKey: apiKey)
                await finishLogin()
            case .mfaRequired(let token):
                mfaSessionToken = token
                errorMessage = nil
                focus = .mfa
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishLogin() async {
        await library.loadPodcasts()
        await library.loadHome()
    }
}

/// Slowly drifting pine-toned mesh gradient.
private struct LoginBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let drift = Float(sin(t * 0.25)) * 0.12
            let sway = Float(cos(t * 0.2)) * 0.1
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + drift, 0.5 + sway], [1, 0.5],
                    [0, 1], [0.5 - sway, 1], [1, 1],
                ],
                colors: [
                    Color(red: 0.05, green: 0.16, blue: 0.14), Color(red: 0.12, green: 0.32, blue: 0.27), Color(red: 0.04, green: 0.12, blue: 0.13),
                    Color(red: 0.18, green: 0.42, blue: 0.36), PineGreen, Color(red: 0.10, green: 0.27, blue: 0.30),
                    Color(red: 0.03, green: 0.08, blue: 0.08), Color(red: 0.08, green: 0.22, blue: 0.19), Color(red: 0.02, green: 0.06, blue: 0.07),
                ])
        }
    }
}
