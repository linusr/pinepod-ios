import Foundation
import Observation

/// Persisted session state: server URL, user id and name in UserDefaults; the
/// API key in the Keychain.
@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private enum Keys {
        static let server = "pinepods_server"
        static let apiKey = "pinepods_api_key"
        static let userId = "pinepods_user_id"
        static let username = "pinepods_username"
    }

    private let defaults = UserDefaults.standard

    var server: String {
        didSet { defaults.set(server, forKey: Keys.server) }
    }
    var apiKey: String {
        didSet { Keychain.set(apiKey, for: Keys.apiKey) }
    }
    var userId: Int {
        didSet { defaults.set(userId, forKey: Keys.userId) }
    }
    var username: String {
        didSet { defaults.set(username, forKey: Keys.username) }
    }

    var isLoggedIn: Bool { !server.isEmpty && !apiKey.isEmpty && userId > 0 }

    /// Skips the login round-trip for values cached from a previous launch.
    private init() {
        server = defaults.string(forKey: Keys.server) ?? ""
        // Keys saved by earlier builds live in UserDefaults; move them to the Keychain.
        if let legacyKey = defaults.string(forKey: Keys.apiKey) {
            Keychain.set(legacyKey, for: Keys.apiKey)
            defaults.removeObject(forKey: Keys.apiKey)
        }
        apiKey = Keychain.string(for: Keys.apiKey) ?? ""
        userId = defaults.integer(forKey: Keys.userId)
        username = defaults.string(forKey: Keys.username) ?? ""
    }

    var client: APIClient {
        APIClient(server: server, apiKey: apiKey)
    }

    func establish(serverUrl: String, username: String, apiKey: String) async throws {
        let server = APIClient.normalizeServer(serverUrl)
        let client = APIClient(server: server, apiKey: apiKey)
        let userId = try await client.userId()
        self.server = server
        self.apiKey = apiKey
        self.userId = userId
        self.username = username
    }

    func logout() {
        server = ""
        apiKey = ""
        userId = 0
        username = ""
    }
}
