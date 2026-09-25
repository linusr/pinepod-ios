import Foundation
import Testing
@testable import PinePods

@Suite("API client")
struct APIClientTests {
    @Test func serverAddressIsNormalized() {
        #expect(APIClient.normalizeServer("  https://pods.example.com///  ") == "https://pods.example.com")
    }

    @Test(arguments: ["https://pods.example.com", "http://192.168.1.10:8040"])
    func validServersBuildEndpoints(server: String) throws {
        let url = try APIClient.endpoint(server, "/api/data/get_key")
        #expect(url.absoluteString == server + "/api/data/get_key")
    }

    /// User-typed addresses must fail cleanly rather than crash.
    @Test(arguments: ["", "https://", "not a url", "ftp://pods.example.com", "https://bad host.com"])
    func invalidServersThrow(server: String) {
        #expect(throws: APIError.self) { try APIClient.endpoint(server, "/api/data/get_key") }
    }

    @Test func redactionDropsTheAPIKey() throws {
        let url = try #require(URL(string: "https://pods.example.com/api/data/stream/1?api_key=pk_secret&user_id=1"))
        let redacted = APIClient.redacted(url)
        #expect(redacted == "https://pods.example.com/api/data/stream/1")
        #expect(!redacted.contains("pk_secret"))
    }

    @Test func streamURLs() {
        let client = APIClient(server: "https://pods.example.com", apiKey: "key")
        #expect(client.streamURL(episodeId: 5, userId: 2, isYoutube: false, isLocal: false) == nil)
        #expect(client.streamURL(episodeId: 5, userId: 2, isYoutube: false, isLocal: true)
            == "https://pods.example.com/api/data/stream/5?api_key=key&user_id=2")
        #expect(client.streamURL(episodeId: 5, userId: 2, isYoutube: true, isLocal: false)?.hasSuffix("&type=youtube") == true)
    }
}

@Suite("Playback helpers")
struct PlaybackHelperTests {
    @Test(arguments: [(1.0, "1×"), (1.25, "1.25×"), (1.5, "1.5×"), (0.75, "0.75×"), (3.0, "3×")])
    func speedLabels(speed: Double, expected: String) {
        #expect(PlaybackSpeed.label(speed) == expected)
    }

    /// SF Symbols only ships numbered skip glyphs for some intervals.
    @Test func skipSymbolsFallBackForUnsupportedIntervals() {
        #expect(SkipSymbol.forward(30) == "goforward.30")
        #expect(SkipSymbol.backward(10) == "gobackward.10")
        #expect(SkipSymbol.forward(25) == "goforward")
        #expect(SkipSymbol.backward(20) == "gobackward")
    }
}

@Suite("Keychain", .serialized)
struct KeychainTests {
    private let account = "kural.tests.\(UUID().uuidString)"

    @Test func storesReplacesAndDeletes() {
        #expect(Keychain.string(for: account) == nil)
        Keychain.set("first", for: account)
        #expect(Keychain.string(for: account) == "first")
        Keychain.set("second", for: account)
        #expect(Keychain.string(for: account) == "second")
        Keychain.set("", for: account)
        #expect(Keychain.string(for: account) == nil)
    }
}

@Suite("Sync outbox")
struct SyncOutboxActionTests {
    @Test func actionsRoundTripAndKnowTheirEpisode() throws {
        let actions: [SyncOutbox.Action] = [
            .position(episodeId: 1, userId: 2, seconds: 42.5, isYoutube: false),
            .completed(episodeId: 3, userId: 2, durationSeconds: 3600, isYoutube: true),
        ]
        let decoded = try JSONDecoder().decode([SyncOutbox.Action].self, from: JSONEncoder().encode(actions))
        #expect(decoded == actions)
        #expect(decoded.map(\.episodeId) == [1, 3])
    }
}

@Suite("Appearance")
struct AccentThemeTests {
    @Test func pineUsesThePrimaryIconAndOthersHaveAlternates() {
        #expect(AccentTheme.pine.iconName == nil)
        #expect(AccentTheme.ocean.iconName == "AppIcon-Ocean")
        let names = AccentTheme.allCases.compactMap(\.iconName)
        #expect(names.count == AccentTheme.allCases.count - 1)
        #expect(Set(names).count == names.count)
    }

    @Test func accentsAreDistinct() {
        #expect(Set(AccentTheme.allCases.map(\.hex)).count == AccentTheme.allCases.count)
        #expect(Set(AccentTheme.allCases.map(\.name)).count == AccentTheme.allCases.count)
    }
}

@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    @Test func roundTripsThroughJSON() throws {
        let episode = WidgetSnapshot.Episode(
            id: 7, title: "Title", podcast: "Show", artworkFile: "7.jpg", duration: 3600, position: 120)
        let snapshot = WidgetSnapshot(
            nowPlaying: .init(episode: episode, isPlaying: true, speed: 1.5, capturedAt: Date(timeIntervalSince1970: 1_000)),
            upNext: [episode], accentHex: AccentTheme.teal.hex, skipBackSeconds: 15, skipForwardSeconds: 45)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.nowPlaying?.episode == episode)
        #expect(decoded.nowPlaying?.speed == 1.5)
        #expect(decoded.upNext == [episode])
        #expect(decoded.accentHex == AccentTheme.teal.hex)
        #expect(decoded.skipForwardSeconds == 45)
    }
}
