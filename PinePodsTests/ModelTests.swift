import Foundation
import Testing
@testable import PinePods

@Suite("Episode model")
struct EpisodeModelTests {
    @Test func progressAndRemainingTime() {
        let episode = Fixtures.episode(1, duration: 3600, listened: 900)
        #expect(episode.savedPosition == 900)
        #expect(episode.progressPercentage == 25)
        #expect(episode.remainingSeconds == 2700)
        #expect(!episode.isNearlyFinished)
    }

    /// `record_podcast_history` stores position × 100; such values must not look like progress.
    @Test func positionPastTheEndIsIgnored() {
        let episode = Fixtures.episode(1, duration: 3734, listened: 2_586_400)
        #expect(episode.savedPosition == nil)
        #expect(episode.progressPercentage == 0)
        #expect(episode.remainingSeconds == 3734)
    }

    @Test func nearlyFinished() {
        #expect(Fixtures.episode(1, duration: 3000, listened: 2950).isNearlyFinished)
        #expect(Fixtures.episode(2, completed: true).isNearlyFinished)
        #expect(!Fixtures.episode(3, duration: 3000, listened: 100).isNearlyFinished)
    }

    @Test func parsingToleratesKeyCaseAndNumbersAsStrings() {
        let episode = PinepodsEpisode.fromJSON([
            "Episodeid": "42", "Podcastname": "Show", "Episodetitle": "Title",
            "Episodeduration": "1800", "Completed": 1, "is_youtube": "true",
        ])
        #expect(episode.episodeId == 42)
        #expect(episode.podcastName == "Show")
        #expect(episode.episodeDuration == 1800)
        #expect(episode.completed)
        #expect(episode.isYoutube)
    }

    @Test func updatedKeepsUnchangedFields() {
        let episode = Fixtures.episode(7, saved: true)
        let updated = episode.updated(completed: true)
        #expect(updated.completed)
        #expect(updated.saved)
        #expect(updated.episodeTitle == episode.episodeTitle)
    }

    @Test func episodesRoundTripThroughJSON() throws {
        let episode = Fixtures.episode(9, listened: 120, listenedDaysAgo: 1, saved: true)
        let decoded = try JSONDecoder().decode(PinepodsEpisode.self, from: JSONEncoder().encode(episode))
        #expect(decoded == episode)
    }

    @Test func categoriesNormalize() {
        #expect(JSON.categories(" Comedy, News ") == "Comedy, News")
        #expect(JSON.categories("") == nil)
        #expect(JSON.categories(["1": "Comedy"]) == "Comedy")
        #expect(JSON.categories(NSNull()) == nil)
    }
}

@Suite("Formatters")
struct FormatterTests {
    @Test(arguments: [
        (0, "0m"), (30, "<1m"), (60, "1m"), (2700, "45m"), (3600, "1h"), (4320, "1h 12m"), (-5, "0m"),
    ])
    func compactDuration(seconds: Int, expected: String) {
        #expect(Formatters.compactDuration(seconds: seconds) == expected)
    }

    @Test(arguments: [(0, "0:00"), (65, "1:05"), (3725, "1:02:05")])
    func clockDuration(seconds: Int, expected: String) {
        #expect(Formatters.duration(seconds: seconds) == expected)
    }

    @Test func relativeDates() {
        #expect(Formatters.relativeDate(Fixtures.ago(0)) == "Today")
        #expect(Formatters.relativeDate(Fixtures.ago(1)) == "Yesterday")
        #expect(Formatters.relativeDate(Fixtures.ago(3)) == "3 days ago")
        #expect(!Formatters.relativeDate(Fixtures.ago(40)).contains("ago"))
        #expect(Formatters.relativeDate("garbage") == "garbage")
    }

    @Test(arguments: ["2026-09-20 10:11:12", "2026-09-20T10:11:12", "2026-09-20T10:11:12+0000", "2026-09-20"])
    func parsesServerDateFormats(raw: String) {
        #expect(Formatters.parseDate(raw) != nil)
    }
}

@Suite("Show notes")
struct HTMLTextTests {
    @Test func blocksBecomeParagraphsAndListsBecomeBullets() {
        let text = HTMLText.plainText("<p>Intro</p><ul><li>One</li><li>Two</li></ul><p>Outro<br>line</p>")
        #expect(text == "Intro\n\n• One\n• Two\n\nOutro\nline")
    }

    @Test func entitiesDecode() {
        #expect(HTMLText.plainText("Tom &amp; Jerry &#8217;s &#x2014; &nbsp;ok") == "Tom & Jerry ’s — ok")
    }

    @Test func plainTextPassesThrough() {
        #expect(HTMLText.plainText("No markup here") == "No markup here")
    }

    @Test func previewIsSingleParagraphAndSurvivesCutTags() {
        let long = "<p>" + String(repeating: "word ", count: 200) + "</p><a href=\"https://example.com/very/long"
        let preview = HTMLText.preview(long)
        #expect(!preview.contains("<"))
        #expect(!preview.contains("\n"))
    }
}
