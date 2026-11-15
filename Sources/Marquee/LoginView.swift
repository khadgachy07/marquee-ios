#if os(iOS)
import MarqueeCore
import SwiftUI

/// "Who's watching?": connect to the server, pick a profile, enter a password if it has one.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var serverText = ""
    @State private var serverName: String?
    @State private var users: [UserDto] = []
    @State private var error: String?
    @State private var connecting = false
    @State private var signInTarget: SignInTarget?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Wordmark().padding(.top, 40)

                if serverName != nil {
                    Text("Who’s watching?").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 20)], spacing: 20) {
                        ForEach(users) { user in
                            Button { pick(user) } label: { profileTile(user) }
                                .buttonStyle(.plain)
                        }
                        Button { signInTarget = SignInTarget(user: nil) } label: { addTile }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(serverName.map { "Connected to \($0)" } ?? "Jellyfin server")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        TextField("http://server:8096", text: $serverText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { Task { await connect() } }
                            .textFieldStyle(.roundedBorder)
                        Button(connecting ? "…" : "Connect") { Task { await connect() } }
                            .buttonStyle(.bordered)
                            .disabled(connecting)
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .task {
            serverText = model.client.server.absoluteString
            await connect()
        }
        .sheet(item: $signInTarget) { target in
            SignInSheet(user: target.user)
                .presentationDetents([.medium])
        }
    }

    private func profileTile(_ user: UserDto) -> some View {
        VStack(spacing: 8) {
            Group {
                if let url = model.client.userImageURL(user) {
                    RemoteImage(url: url)
                } else {
                    Text(user.name.prefix(1).uppercased())
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hue: Double(abs(user.name.hashValue % 360)) / 360, saturation: 0.6, brightness: 0.5))
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(user.name).font(.subheadline).lineLimit(1)
        }
    }

    private var addTile: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.largeTitle)
                .frame(width: 96, height: 96)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray, lineWidth: 2))
            Text("Sign in").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func connect() async {
        let text = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            error = "Enter the full server address, like \(AppModel.defaultServer.absoluteString)"
            return
        }
        connecting = true
        defer { connecting = false }
        model.setServer(url)
        do {
            let info = try await model.client.publicInfo()
            users = (try? await model.client.publicUsers()) ?? []
            serverName = info.serverName ?? "Jellyfin"
            error = nil
        } catch {
            serverName = nil
            users = []
            self.error = "Couldn’t reach Jellyfin at that address. Is Tailscale on? (\(error.localizedDescription))"
        }
    }

    private func pick(_ user: UserDto) {
        if user.needsPassword {
            signInTarget = SignInTarget(user: user)
        } else {
            Task {
                do { try await model.signIn(username: user.name, password: "") }
                catch { signInTarget = SignInTarget(user: user) }
            }
        }
    }
}

struct SignInTarget: Identifiable {
    let id = UUID()
    let user: UserDto?
}

private struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let user: UserDto?
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if let user {
                    Text(user.name).font(.headline)
                } else {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { Task { await submit() } }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign In") { Task { await submit() } }
                        .disabled(busy || (user == nil && username.isEmpty))
                }
            }
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            try await model.signIn(username: user?.name ?? username.trimmingCharacters(in: .whitespaces), password: password)
            dismiss()
        } catch {
            self.error = (error as? JellyfinError) == .http(401)
                ? "Incorrect username or password."
                : error.localizedDescription
        }
    }
}
#endif
