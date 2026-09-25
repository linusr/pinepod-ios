import SwiftUI
import WidgetKit

@main
struct KuralWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingComplication()
    }
}

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(ComplicationEntry(date: .now, snapshot: SharedContainer.loadSnapshot()))
    }

    /// The watch app reloads timelines whenever the iPhone sends new state;
    /// progress in between comes from timer intervals.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        completion(Timeline(entries: [ComplicationEntry(date: .now, snapshot: SharedContainer.loadSnapshot())], policy: .never))
    }
}

struct NowPlayingComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedContainer.widgetKind, provider: ComplicationProvider()) { entry in
            ComplicationView(snapshot: entry.snapshot)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("The current Kural episode and its progress.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family

    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .accessoryCorner: corner
        default: circular
        }
    }

    private var symbol: String {
        snapshot.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill"
    }

    private var circular: some View {
        ZStack {
            if let now = snapshot.nowPlaying {
                Progress(now: now)
                    .progressViewStyle(.circular)
            }
            Image(systemName: snapshot.nowPlaying == nil ? "headphones" : symbol)
                .font(.body.weight(.bold))
                .widgetAccentable()
        }
    }

    @ViewBuilder
    private var rectangular: some View {
        if let now = snapshot.nowPlaying {
            VStack(alignment: .leading, spacing: 1) {
                Label(now.episode.podcast, systemImage: now.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .widgetAccentable()
                Text(now.episode.title)
                    .font(.headline)
                    .lineLimit(1)
                Progress(now: now)
                    .progressViewStyle(.linear)
            }
        } else {
            VStack(alignment: .leading) {
                Label("Kural", systemImage: "headphones")
                    .font(.headline)
                    .widgetAccentable()
                Text(snapshot.upNext.first?.title ?? "Nothing playing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var inline: some View {
        Label(snapshot.nowPlaying?.episode.title ?? "Nothing playing",
              systemImage: snapshot.nowPlaying?.isPlaying == true ? "waveform" : "headphones")
    }

    private var corner: some View {
        Image(systemName: snapshot.nowPlaying == nil ? "headphones" : symbol)
            .font(.title3.weight(.semibold))
            .widgetAccentable()
            .widgetLabel {
                if let now = snapshot.nowPlaying {
                    Progress(now: now)
                } else {
                    Text("Kural")
                }
            }
    }
}

/// Live while playing: WidgetKit animates timer-interval progress on its own.
private struct Progress: View {
    let now: WidgetSnapshot.NowPlaying

    var body: some View {
        let episode = now.episode
        let rate = max(now.speed, 0.1)
        let start = now.capturedAt.addingTimeInterval(-episode.position / rate)
        let end = start.addingTimeInterval(max(episode.duration, 1) / rate)
        if now.isPlaying, episode.duration > 0, end > .now {
            ProgressView(timerInterval: start...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
        } else {
            ProgressView(value: episode.duration > 0 ? min(episode.position / episode.duration, 1) : 0)
        }
    }
}
