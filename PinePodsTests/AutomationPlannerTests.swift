import Foundation
import Testing
@testable import PinePods

@Suite("Automation planner")
struct AutomationPlannerTests {
    private typealias F = Fixtures

    private func input(
        history: [PinepodsEpisode] = [], feed: [PinepodsEpisode] = [], queue: [PinepodsEpisode] = [],
        phone: [PinepodsEpisode] = [], server: [PinepodsEpisode] = [], shows: [PinepodsEpisode]? = nil,
        handled: Set<Int> = [], protected: Set<Int> = []
    ) -> AutomationInput {
        AutomationInput(
            now: F.now, history: history, historyCoversDays: 31, feed: feed, queue: queue,
            phoneDownloads: phone, serverDownloads: server, showEpisodes: shows,
            handledIds: handled, protectedIds: protected)
    }

    /// Show A: two plays in the last week (regular). B: one play. C: plays 45+ days ago.
    private let history = [
        F.episode(1, show: "A", completed: true, listenedDaysAgo: 2),
        F.episode(2, show: "A", listenedDaysAgo: 5),
        F.episode(3, show: "B", completed: true, listenedDaysAgo: 1),
        F.episode(4, show: "C", completed: true, listenedDaysAgo: 45),
        F.episode(5, show: "C", completed: true, listenedDaysAgo: 50),
        F.episode(20, show: "A", completed: true, listenedDaysAgo: 0.5),
        F.episode(21, show: "A", completed: true, listenedDaysAgo: 3),
    ]

    @Test func regularShowsGetNewEpisodesOnce() {
        var rules = AutomationRules()
        rules.downloadRegular = true
        rules.queueRegular = true
        let feed = [
            F.episode(10, show: "A", published: 3),
            F.episode(11, show: "A", published: 10),            // outside the 7-day window
            F.episode(12, show: "B", published: 2),             // show not regular
            F.episode(13, show: "A", published: 1),             // handled on an earlier run
            F.episode(14, show: "A", published: 2, completed: true),
            F.episode(15, show: "A", published: 4),             // already queued
            F.episode(16, show: "C", published: 1),             // was regular, isn't now
        ]
        let plan = AutomationPlanner.plan(
            rules: rules,
            input: input(history: history, feed: feed, queue: [F.episode(15, show: "A", published: 4)], handled: [13]))

        #expect(plan.regularShows == ["A"])
        #expect(plan.download.ids == [10, 15])
        #expect(plan.queue.ids == [10])
        #expect(plan.handled.sorted() == [10, 15])
    }

    @Test func regularThresholdIsRespected() {
        var rules = AutomationRules()
        rules.queueRegular = true
        rules.regularMinEpisodes = 5
        let plan = AutomationPlanner.plan(
            rules: rules, input: input(history: history, feed: [F.episode(10, show: "A", published: 1)]))
        #expect(plan.regularShows.isEmpty)
        #expect(plan.queue.isEmpty)
    }

    @Test func playedDownloadsAreRemovedAfterTheirDelay() {
        var rules = AutomationRules()
        rules.removePlayedFromPhoneAfterDays = 1
        rules.removePlayedFromServerAfterDays = 30
        let phone = [
            F.episode(21, show: "A", completed: true),          // played 3 days ago → remove
            F.episode(20, show: "A", completed: true),          // played 12 h ago → keep
            F.episode(30, show: "A"),                           // unplayed → keep
            F.episode(31, show: "D", completed: true),          // played before the history window → remove
            F.episode(32, show: "D", completed: true),          // playing now → keep
        ]
        let server = [
            F.episode(21, show: "A", completed: true, downloaded: true),
            F.episode(31, show: "D", completed: true, downloaded: true),
            F.episode(33, show: "D", downloaded: true),
        ]
        let plan = AutomationPlanner.plan(
            rules: rules, input: input(history: history, phone: phone, server: server, protected: [32]))

        #expect(plan.removeFromPhone.ids == [21, 31])
        #expect(plan.removeFromServer.ids == [31])
    }

    @Test func removingRightAwayIncludesJustPlayed() {
        var rules = AutomationRules()
        rules.removePlayedFromPhoneAfterDays = 0
        let plan = AutomationPlanner.plan(
            rules: rules, input: input(history: history, phone: [F.episode(20, show: "A", completed: true)]))
        #expect(plan.removeFromPhone.ids == [20])
    }

    @Test func oldUnplayedEpisodesAreMarkedAndCleaned() {
        var rules = AutomationRules()
        rules.clearUnplayedAfterDays = 60
        let shows = [
            F.episode(40, show: "E", published: 70),
            F.episode(41, show: "E", published: 90),
            F.episode(42, show: "E", published: 100, downloaded: true),
            F.episode(44, show: "E", published: 80),                    // playing now
            F.episode(45, show: "E", published: 80, saved: true),       // saved
            F.episode(46, show: "E", published: 20),                    // recent
            F.episode(47, show: "E", published: 90, completed: true),   // already played
            F.episode(1, show: "A", published: 65),                     // played per history
        ]
        let plan = AutomationPlanner.plan(rules: rules, input: input(
            history: history,
            queue: [F.episode(43, show: "F", published: 75)],
            phone: [F.episode(41, show: "E", published: 90)],
            server: [F.episode(42, show: "E", published: 100, downloaded: true)],
            shows: shows, protected: [44]))

        #expect(plan.markPlayed.ids == [40, 41, 42, 43])
        #expect(plan.removeFromPhone.ids == [41])
        #expect(plan.removeFromServer.ids == [42])
    }

    @Test func savedEpisodesAreClearedWhenKeepSavedIsOff() {
        var rules = AutomationRules()
        rules.clearUnplayedAfterDays = 60
        rules.keepSaved = false
        let plan = AutomationPlanner.plan(
            rules: rules, input: input(shows: [F.episode(45, published: 80, saved: true)]))
        #expect(plan.markPlayed.ids == [45])
    }

    @Test func withoutTheDailySweepOnlyQueueAndDownloadsAreConsidered() {
        var rules = AutomationRules()
        rules.clearUnplayedAfterDays = 60
        let plan = AutomationPlanner.plan(rules: rules, input: input(
            queue: [F.episode(43, published: 75)], phone: [F.episode(41, published: 90)], shows: nil))
        #expect(plan.markPlayed.ids == [41, 43])
    }

    @Test func episodesWithoutAPublishDateAreNeverMarked() {
        var rules = AutomationRules()
        rules.clearUnplayedAfterDays = 30
        let undated = PinepodsEpisode.fromJSON(["episodeid": 90, "episodepubdate": "not a date"])
        let plan = AutomationPlanner.plan(rules: rules, input: input(shows: [undated]))
        #expect(plan.markPlayed.isEmpty)
    }

    @Test func allRulesOffProducesNothing() {
        let plan = AutomationPlanner.plan(rules: AutomationRules(), input: input(
            history: history, feed: [F.episode(10, show: "A")], phone: [F.episode(20, show: "A", completed: true)],
            shows: [F.episode(40, published: 200)]))
        #expect(plan.isEmpty)
    }

    @Test func rulesRoundTripThroughJSON() throws {
        var rules = AutomationRules()
        rules.downloadRegular = true
        rules.clearUnplayedAfterDays = 90
        let decoded = try JSONDecoder().decode(AutomationRules.self, from: JSONEncoder().encode(rules))
        #expect(decoded == rules)
        #expect(decoded.anyEnabled)
        #expect(decoded.enabledCount == 2)
        #expect(!AutomationRules().anyEnabled)
    }
}
