import AppIntents
import SwiftUI
import WidgetKit

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let snapshot = SharedContainer.loadSnapshot()
        completion(NowPlayingEntry(date: .now, snapshot: context.isPreview && snapshot.nowPlaying == nil ? .sample : snapshot))
    }

    /// The app reloads the timeline on every discrete change; progress in
    /// between is drawn from timer intervals, so one entry is enough.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [NowPlayingEntry(date: .now, snapshot: SharedContainer.loadSnapshot())], policy: .never))
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedContainer.widgetKind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("Control the current episode and see what's up next.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: NowPlayingEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var accent: Color { Color(hex: snapshot.accentHex) }

    var body: some View {
        content
            .widgetURL(URL(string: "kural://nowplaying"))
            .containerBackground(for: .widget) {
                if family.isAccessory {
                    Color.clear
                } else {
                    LinearGradient(
                        colors: [accent.mix(with: .black, by: 0.35), accent.mix(with: .black, by: 0.8)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        case .systemSmall: small
        case .systemLarge: large
        default: medium
        }
    }

    // MARK: - Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Artwork(file: snapshot.nowPlaying?.episode.artworkFile, size: 58)
                Spacer(minLength: 0)
                PlayButton(isPlaying: snapshot.nowPlaying?.isPlaying == true, size: 34)
            }
            Spacer(minLength: 0)
            if let now = snapshot.nowPlaying {
                Text(now.episode.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                ProgressBar(now: now)
            } else {
                emptyMessage
            }
        }
        .foregroundStyle(.white)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            Artwork(file: snapshot.nowPlaying?.episode.artworkFile, size: 104)
            VStack(alignment: .leading, spacing: 4) {
                if let now = snapshot.nowPlaying {
                    Text(now.episode.podcast.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    Text(now.episode.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 2)
                    ProgressBar(now: now, showsTime: true)
                    transport
                } else {
                    emptyMessage
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            medium
                .frame(height: 118)
            Divider().overlay(.white.opacity(0.25))
            Text("UP NEXT")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.65))
            if snapshot.upNext.isEmpty {
                Text("Your queue is empty.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
            ForEach(snapshot.upNext.prefix(3)) { episode in
                HStack(spacing: 10) {
                    Artwork(file: episode.artworkFile, size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(episode.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        Text(episode.podcast)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button(intent: PlayEpisodeIntent(episodeId: episode.id)) {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.2), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button(intent: SkipIntent(seconds: -snapshot.skipBackSeconds)) {
                Image(systemName: skipSymbol("gobackward", snapshot.skipBackSeconds))
                    .font(.title3)
            }
            PlayButton(isPlaying: snapshot.nowPlaying?.isPlaying == true, size: 36)
            Button(intent: SkipIntent(seconds: snapshot.skipForwardSeconds)) {
                Image(systemName: skipSymbol("goforward", snapshot.skipForwardSeconds))
                    .font(.title3)
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyMessage: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nothing playing")
                .font(.subheadline.weight(.semibold))
            Text(snapshot.upNext.first.map { "Up next: \($0.title)" } ?? "Open Kural to start listening.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private var rectangular: some View {
        if let now = snapshot.nowPlaying {
            VStack(alignment: .leading, spacing: 2) {
                Label(now.episode.podcast, systemImage: now.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Text(now.episode.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                ProgressBar(now: now)
            }
        } else {
            Label("Nothing playing", systemImage: "headphones")
                .font(.caption)
        }
    }

    private var circular: some View {
        ZStack {
            if let now = snapshot.nowPlaying {
                ProgressBar(now: now, style: .circular)
            }
            Image(systemName: snapshot.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill")
                .font(.body.weight(.bold))
        }
        .widgetAccentable()
    }

    private func skipSymbol(_ base: String, _ seconds: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }
}

// MARK: - Components

private struct PlayButton: View {
    let isPlaying: Bool
    let size: CGFloat

    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .frame(width: size, height: size)
                .background(.white.opacity(0.22), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// Live while playing: WidgetKit animates timer-interval progress on its own.
private struct ProgressBar: View {
    enum Style { case linear, circular }

    let now: WidgetSnapshot.NowPlaying
    var showsTime = false
    var style: Style = .linear

    var body: some View {
        let episode = now.episode
        let rate = max(now.speed, 0.1)
        let start = now.capturedAt.addingTimeInterval(-episode.position / rate)
        let end = start.addingTimeInterval(max(episode.duration, 1) / rate)
        VStack(alignment: .leading, spacing: 3) {
            Group {
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
            .modifier(ProgressStyle(style: style))
            .tint(.white)

            if showsTime, episode.duration > 0 {
                Group {
                    if now.isPlaying, end > .now {
                        Text(timerInterval: Date.now...end, countsDown: true)
                    } else {
                        Text(Duration.seconds(max(episode.duration - episode.position, 0)).formatted(.time(pattern: .hourMinuteSecond)))
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

private struct ProgressStyle: ViewModifier {
    let style: ProgressBar.Style

    func body(content: Content) -> some View {
        switch style {
        case .linear: content.progressViewStyle(.linear)
        case .circular: content.progressViewStyle(.circular)
        }
    }
}

private struct Artwork: View {
    let file: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let file, let folder = SharedContainer.artworkFolder,
               let image = UIImage(contentsOfFile: folder.appending(path: file).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.15)
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.35, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}

private extension WidgetFamily {
    var isAccessory: Bool {
        self == .accessoryCircular || self == .accessoryRectangular || self == .accessoryInline
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension WidgetSnapshot {
    static let sample = WidgetSnapshot(
        nowPlaying: .init(
            episode: .init(id: 1, title: "Why Every City Is Rethinking Its Streets", podcast: "The Daily Signal",
                           artworkFile: nil, duration: 3600, position: 1300),
            isPlaying: false, speed: 1, capturedAt: .now),
        upNext: [.init(id: 2, title: "What the Old Maps Got Right", podcast: "Hard Fork Café",
                       artworkFile: nil, duration: 2700, position: 0)],
        accentHex: 0x549E8A, skipBackSeconds: 10, skipForwardSeconds: 30)
}
