#if os(iOS)
import Foundation
import MarqueeCore
import Observation
import Security
import UIKit

/// Signed-in state: the Jellyfin client and user. The access token lives in the Keychain.
@MainActor
@Observable
final class AppModel {
    /// Example shown in the address field; there is no built-in server.
    static let exampleServer = "http://192.168.1.10:8096"
    /// Stand-in until someone enters their server; never contacted (the sign-in screen asks first).
    private static let unsetServer = URL(string: "http://localhost:8096")!

    private(set) var client: JellyfinClient
    private(set) var user: UserDto?

    var isSignedIn: Bool { user != nil && client.token != nil }

    /// The server this phone last connected to, if any.
    var savedServer: URL? {
        UserDefaults.standard.string(forKey: "server").flatMap(JellyfinClient.serverURL(from:))
    }

    init() {
        let defaults = UserDefaults.standard
        let savedServer = defaults.string(forKey: "server").flatMap(JellyfinClient.serverURL(from:))
        var deviceId = defaults.string(forKey: "deviceId") ?? ""
        if deviceId.isEmpty {
            deviceId = UUID().uuidString
            defaults.set(deviceId, forKey: "deviceId")
        }
        let server = savedServer ?? Self.unsetServer
        var client = JellyfinClient(server: server, deviceId: deviceId, deviceName: UIDevice.current.name)

        var savedUser: UserDto?
        if let data = defaults.data(forKey: "user"),
           let user = try? JSONDecoder().decode(UserDto.self, from: data),
           let token = Keychain.get("token") {
            client.token = token
            client.userId = user.id
            savedUser = user
        }
        self.client = client
        self.user = savedUser
    }

    func setServer(_ url: URL) {
        client.server = url
        UserDefaults.standard.set(url.absoluteString, forKey: "server")
    }

    func signIn(username: String, password: String) async throws {
        let result = try await client.authenticate(username: username, password: password)
        client.token = result.accessToken
        client.userId = result.user.id
        user = result.user
        Keychain.set(result.accessToken, for: "token")
        UserDefaults.standard.set(try? JSONEncoder().encode(result.user), forKey: "user")
    }

    func signOut() {
        let old = client
        Task { await old.logout() }
        client.token = nil
        client.userId = nil
        user = nil
        Keychain.set(nil, for: "token")
        UserDefaults.standard.removeObject(forKey: "user")
    }

    /// A message for an error; signs out when the server says the sign-in expired.
    func message(for error: Error) -> String {
        if (error as? JellyfinError) == .http(401), isSignedIn { signOut() }
        return error.localizedDescription
    }
}

/// Tiny Keychain wrapper for the access token.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "marquee",
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var add = query(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
