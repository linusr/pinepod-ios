import Foundation

enum APIError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case invalidServerURL
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .invalidResponse: return "Invalid response from server"
        case .invalidServerURL: return "That server address isn't a valid URL."
        case .server(let message): return message
        }
    }
}

enum LoginStage: Sendable {
    case authenticated(apiKey: String)
    case mfaRequired(sessionToken: String)
}

/// REST client for the PinePods self-hosted server. Mirrors the Flutter
/// client's PinepodsService: Basic-auth key exchange, `Api-Key` header on
/// every subsequent request, 15 s timeout.
struct APIClient: Sendable {
    let server: String
    let apiKey: String

    /// One session for the whole app: requests reuse keep-alive connections
    /// instead of paying a fresh TCP+TLS handshake per call (mirrors the Dart
    /// client's shared http.Client).
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var session: URLSession { Self.sharedSession }

    static func normalizeServer(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    /// Server addresses are typed by the user, so they're validated rather than force-unwrapped.
    static func endpoint(_ server: String, _ path: String) throws -> URL {
        guard let url = URL(string: "\(server)\(path)"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else {
            throw APIError.invalidServerURL
        }
        return url
    }

    /// Scheme, host and path only: stream URLs carry the API key in their query.
    static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<url>" }
        components.query = nil
        return components.string ?? "<url>"
    }

    // MARK: - Auth (no API key needed)

    static func verifyInstance(_ serverUrl: String) async -> Bool {
        guard let url = try? endpoint(normalizeServer(serverUrl), "/api/pinepods_check") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return JSON.bool(json, "pinepods_instance")
        } catch {
            return false
        }
    }

    /// First login step: Basic-auth key exchange. Returns either the API key or
    /// an MFA challenge (server-side TOTP sessions expire after 5 minutes).
    static func startLogin(serverUrl: String, username: String, password: String) async throws -> LoginStage {
        let server = normalizeServer(serverUrl)
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()

        var request = URLRequest(url: try endpoint(server, "/api/data/get_key"))
        request.timeoutInterval = 15
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.server(message: "Login failed — check server URL and credentials")
        }

        let status = JSON.str(json, "status") ?? ""
        if status == "mfa_required", let token = JSON.str(json, "mfa_session_token"), !token.isEmpty {
            return .mfaRequired(sessionToken: token)
        }
        guard let apiKey = JSON.str(json, "retrieved_key"), !apiKey.isEmpty else {
            throw APIError.server(message: "Login failed — server did not return an API key")
        }
        return .authenticated(apiKey: apiKey)
    }

    /// Completes an MFA login with a TOTP code, returning the API key.
    static func verifyMfa(serverUrl: String, sessionToken: String, code: String) async throws -> String {
        let server = normalizeServer(serverUrl)
        var request = URLRequest(url: try endpoint(server, "/api/data/verify_mfa_and_get_key"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "mfa_session_token": sessionToken,
            "mfa_code": code,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = JSON.str(json, "retrieved_key"), !apiKey.isEmpty else {
            throw APIError.server(message: "MFA verification failed — check the code and try again")
        }
        return apiKey
    }

    // MARK: - Requests

    private func request(path: String, query: [URLQueryItem] = [], method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: try Self.endpoint(server, path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidServerURL
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        guard let url = components.url else { throw APIError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.timeoutInterval = 15
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.server(message: "Server returned \(http.statusCode)")
        }
        return data
    }

    private func json(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    /// True on 200, false when the server rejects the request (4xx). Throws on
    /// transport errors and 5xx, which usually mean the server is unreachable
    /// behind a proxy and the call is worth retrying.
    private func post(path: String, body: [String: Any]) async throws -> Bool {
        try await accepted(request(path: path, method: "POST", body: body))
    }

    private func accepted(_ request: URLRequest) async throws -> Bool {
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 500 {
            throw APIError.server(message: "Server returned \(status)")
        }
        return status == 200
    }

    // MARK: - Identity

    /// Resolves the user id for the current API key via `/api/data/get_user`
    /// (the `id_from_api_key` endpoint no longer exists on current backends).
    func userId() async throws -> Int {
        let data = try await send(try request(path: "/api/data/get_user"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              JSON.str(json, "status") == "success",
              let id = JSON.intOrNull(json, "retrieved_id") else {
            throw APIError.server(message: "Could not resolve user id from API key")
        }
        return id
    }

    // MARK: - Library

    func userPodcasts(userId: Int) async throws -> [Podcast] {
        let data = try await send(try request(path: "/api/data/return_pods/\(userId)"))
        guard let json = try json(data) as? [String: Any] else { throw APIError.invalidResponse }
        return JSON.array(json, "pods").map(Podcast.fromJSON)
    }

    func recentEpisodes(userId: Int, limit: Int = 50, offset: Int = 0) async throws -> (episodes: [PinepodsEpisode], total: Int) {
        let data = try await send(try request(
            path: "/api/data/return_episodes/\(userId)",
            query: [URLQueryItem(name: "limit", value: "\(limit)"), URLQueryItem(name: "offset", value: "\(offset)")]
        ))
        let parsed = try json(data)
        if let dict = parsed as? [String: Any] {
            return (JSON.array(dict, "episodes").map(PinepodsEpisode.fromJSON), JSON.int(dict, "total"))
        }
        if let arr = parsed as? [[String: Any]] {
            let episodes = arr.map(PinepodsEpisode.fromJSON)
            return (episodes, episodes.count)
        }
        return ([], 0)
    }

    func podcastEpisodes(userId: Int, podcastId: Int) async throws -> [PinepodsEpisode] {
        let data = try await send(try request(
            path: "/api/data/podcast_episodes",
            query: [URLQueryItem(name: "user_id", value: "\(userId)"), URLQueryItem(name: "podcast_id", value: "\(podcastId)")]
        ))
        guard let dict = try json(data) as? [String: Any] else { throw APIError.invalidResponse }
        return JSON.array(dict, "episodes").map(PinepodsEpisode.fromJSON)
    }

    func homeOverview(userId: Int) async throws -> HomeOverview {
        let data = try await send(try request(
            path: "/api/data/home_overview",
            query: [URLQueryItem(name: "user_id", value: "\(userId)")]
        ))
        guard let dict = try json(data) as? [String: Any] else { throw APIError.invalidResponse }
        return HomeOverview.fromJSON(dict)
    }

    func episodeMetadata(episodeId: Int, userId: Int, isYoutube: Bool) async throws -> PinepodsEpisode? {
        let data = try await send(try request(
            path: "/api/data/get_episode_metadata",
            method: "POST",
            body: ["episode_id": episodeId, "user_id": userId, "person_episode": false, "is_youtube": isYoutube]
        ))
        guard let dict = try json(data) as? [String: Any],
              let episode = dict["episode"] as? [String: Any] else { return nil }
        return PinepodsEpisode.fromJSON(episode)
    }

    // MARK: - Playback tracking

    /// Saves the playback position in seconds. The backend keeps the larger of
    /// the stored and sent values. Positions must not go through
    /// `record_podcast_history`, which stores them multiplied by 100.
    func recordListenDuration(episodeId: Int, userId: Int, durationSeconds: Double, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/record_listen_duration", body: [
            "episode_id": episodeId, "user_id": userId, "listen_duration": durationSeconds, "is_youtube": isYoutube,
        ])
    }

    func markCompleted(episodeId: Int, userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/mark_episode_completed", body: [
            "episode_id": episodeId, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    func markUncompleted(episodeId: Int, userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/mark_episode_uncompleted", body: [
            "episode_id": episodeId, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    func saveEpisode(episodeId: Int, userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/save_episode", body: [
            "episode_id": episodeId, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    func removeSavedEpisode(episodeId: Int, userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/remove_saved_episode", body: [
            "episode_id": episodeId, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    func incrementPlayed(userId: Int) async throws {
        let request = try request(path: "/api/data/increment_played/\(userId)", method: "PUT")
        _ = try await send(request)
    }

    func incrementListenTime(userId: Int) async throws {
        let request = try request(path: "/api/data/increment_listen_time/\(userId)", method: "PUT")
        _ = try await send(request)
    }

    func playEpisodeDetails(userId: Int, podcastId: Int, isYoutube: Bool) async throws -> PlayEpisodeDetails {
        let data = try await send(try request(
            path: "/api/data/get_play_episode_details",
            method: "POST",
            body: ["user_id": userId, "podcast_id": podcastId, "is_youtube": isYoutube]
        ))
        guard let dict = try json(data) as? [String: Any] else { return .default }
        return PlayEpisodeDetails.fromJSON(dict)
    }

    func podcastIdFromEpisode(episodeId: Int, userId: Int, isYoutube: Bool) async throws -> Int {
        let data = try await send(try request(
            path: "/api/data/get_podcast_id_from_ep_id",
            query: [
                URLQueryItem(name: "episode_id", value: "\(episodeId)"),
                URLQueryItem(name: "user_id", value: "\(userId)"),
                URLQueryItem(name: "is_youtube", value: isYoutube ? "true" : "false"),
            ]
        ))
        guard let dict = try json(data) as? [String: Any] else { return 0 }
        return JSON.int(dict, "podcast_id")
    }

    // MARK: - Downloads (server-side)

    func downloadEpisode(episodeId: Int, userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/download_podcast", body: [
            "episode_id": episodeId, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    func deleteDownloadedEpisode(episodeId: Int, userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/delete_episode", body: [
            "episode_id": episodeId, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    func savedEpisodes(userId: Int) async throws -> [PinepodsEpisode] {
        let data = try await send(try request(path: "/api/data/saved_episode_list/\(userId)"))
        guard let dict = try json(data) as? [String: Any] else { throw APIError.invalidResponse }
        return JSON.array(dict, "saved_episodes").map(PinepodsEpisode.fromJSON)
    }

    func queuedEpisodes(userId: Int) async throws -> [PinepodsEpisode] {
        let data = try await send(try request(
            path: "/api/data/get_queued_episodes",
            query: [URLQueryItem(name: "user_id", value: "\(userId)")]
        ))
        guard let dict = try json(data) as? [String: Any] else { throw APIError.invalidResponse }
        return JSON.array(dict, "data").map(PinepodsEpisode.fromJSON)
    }

    // MARK: - Queue

    func queueEpisode(episodeId: Int, userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/queue_pod", body: [
            "episode_id": episodeId, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    func removeQueuedEpisode(episodeId: Int, userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/remove_queued_pod", body: [
            "episode_id": episodeId, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    /// Sets the full queue order; `episodeIds` must list every queued episode.
    func reorderQueue(episodeIds: [Int], userId: Int) async throws -> Bool {
        let request = try request(
            path: "/api/data/reorder_queue",
            query: [URLQueryItem(name: "user_id", value: "\(userId)")],
            method: "POST",
            body: ["episode_ids": episodeIds])
        return try await accepted(request)
    }

    func clearQueue(userId: Int) async throws -> Bool {
        try await post(path: "/api/data/clear_queue", body: ["user_id": userId])
    }

    // MARK: - History and bulk actions

    /// Listening history, most recent first; each entry carries `listenDate`.
    func userHistory(userId: Int, limit: Int, offset: Int) async throws -> [PinepodsEpisode] {
        let data = try await send(try request(
            path: "/api/data/user_history/\(userId)",
            query: [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "offset", value: "\(offset)"),
            ]))
        guard let dict = try json(data) as? [String: Any] else { throw APIError.invalidResponse }
        return JSON.array(dict, "data").map(PinepodsEpisode.fromJSON)
    }

    func bulkMarkCompleted(episodeIds: [Int], userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/bulk_mark_episodes_completed", body: [
            "episode_ids": episodeIds, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    func bulkDeleteServerDownloads(episodeIds: [Int], userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/bulk_delete_downloaded_episodes", body: [
            "episode_ids": episodeIds, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    func bulkQueue(episodeIds: [Int], userId: Int, isYoutube: Bool) async throws -> Bool {
        try await post(path: "/api/data/bulk_queue_episodes", body: [
            "episode_ids": episodeIds, "user_id": userId, "is_youtube": isYoutube,
        ])
    }

    func serverDownloads(userId: Int) async throws -> [PinepodsEpisode] {
        let data = try await send(try request(
            path: "/api/data/download_episode_list",
            query: [URLQueryItem(name: "user_id", value: "\(userId)")]
        ))
        guard let dict = try json(data) as? [String: Any] else { throw APIError.invalidResponse }
        return JSON.array(dict, "downloaded_episodes").map(PinepodsEpisode.fromJSON)
    }

    func downloadTasks(userId: Int) async throws -> [DownloadTask] {
        let data = try await send(try request(path: "/api/tasks/user/\(userId)"))
        guard let arr = try json(data) as? [[String: Any]] else { return [] }
        return arr.map(DownloadTask.fromJSON).filter {
            ["download_episode", "podcast_download", "download_all_episodes"].contains($0.taskType)
        }
    }

    // MARK: - Stream URL

    /// Playback URL for an episode: server stream for downloaded/YouTube
    /// episodes, the original media URL otherwise (matches the Flutter client).
    func streamURL(episodeId: Int, userId: Int, isYoutube: Bool, isLocal: Bool) -> String? {
        if isYoutube {
            return "\(server)/api/data/stream/\(episodeId)?api_key=\(apiKey)&user_id=\(userId)&type=youtube"
        }
        if isLocal {
            return "\(server)/api/data/stream/\(episodeId)?api_key=\(apiKey)&user_id=\(userId)"
        }
        return nil
    }
}
