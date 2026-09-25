import SwiftUI

enum WatchPage: Hashable {
    case nowPlaying, upNext
}

struct ContentView: View {
    @Environment(WatchStore.self) private var store

    @State private var page = WatchPage.nowPlaying

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                NowPlayingScreen(page: $page)
                    .tag(WatchPage.nowPlaying)
                UpNextScreen()
                    .tag(WatchPage.upNext)
            }
            .tabViewStyle(.verticalPage)
            .containerBackground(accent.gradient.opacity(0.45), for: .tabView)
        }
    }

    private var accent: Color { Color(hex: store.snapshot.accentHex) }
}

struct NowPlayingScreen: View {
    @Environment(WatchStore.self) private var store

    @Binding var page: WatchPage

    var body: some View {
        Group {
            if let now = store.snapshot.nowPlaying {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Thumbnail(image: store.image(for: now.episode.artworkFile), size: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(now.episode.title)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(now.episode.podcast)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LiveProgress(now: now)
                    Spacer(minLength: 0)
                    transport(isPlaying: now.isPlaying)
                    status
                }
            } else {
                ContentUnavailableView {
                    Label("Nothing Playing", systemImage: "headphones")
                } description: {
                    Text(store.snapshot.upNext.isEmpty
                         ? "Start an episode on your iPhone."
                         : "Pick an episode from Up Next.")
                } actions: {
                    if !store.snapshot.upNext.isEmpty {
                        Button("Show Up Next") {
                            withAnimation { page = .upNext }
                        }
                    }
                }
            }
        }
        .navigationTitle("Kural")
    }

    private func transport(isPlaying: Bool) -> some View {
        HStack {
            Button {
                store.skip(-store.snapshot.skipBackSeconds)
            } label: {
                Image(systemName: skipSymbol("gobackward", store.snapshot.skipBackSeconds))
                    .font(.title3)
            }
            .accessibilityLabel("Skip back")
            Button {
                store.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Button {
                store.skip(store.snapshot.skipForwardSeconds)
            } label: {
                Image(systemName: skipSymbol("goforward", store.snapshot.skipForwardSeconds))
                    .font(.title3)
            }
            .accessibilityLabel("Skip forward")
        }
        .buttonStyle(.plain)
        .disabled(store.isSending && !store.isReachable)
    }

    @ViewBuilder
    private var status: some View {
        if let error = store.errorMessage {
            Label(error, systemImage: "iphone.slash")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if !store.isReachable {
            Label("iPhone not reachable", systemImage: "iphone.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func skipSymbol(_ base: String, _ seconds: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }
}

struct UpNextScreen: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        List {
            if store.snapshot.upNext.isEmpty {
                Text("Your queue is empty.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.snapshot.upNext) { episode in
                Button {
                    store.play(episode)
                } label: {
                    HStack(spacing: 8) {
                        Thumbnail(image: store.image(for: episode.artworkFile), size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(episode.title)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(2)
                            Text(remaining(episode))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.remove(episode)
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            }
        }
        .navigationTitle("Up Next")
    }

    private func remaining(_ episode: WidgetSnapshot.Episode) -> String {
        let seconds = Int(max(episode.duration - episode.position, 0))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let left = hours > 0 ? "\(hours)h \(minutes)m" : "\(max(minutes, 1))m"
        return "\(episode.podcast) · \(left)"
    }
}

struct Thumbnail: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.15)
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.4, weight: .semibold))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}

/// Live while playing: the timer interval animates without app updates.
struct LiveProgress: View {
    let now: WidgetSnapshot.NowPlaying

    var body: some View {
        let episode = now.episode
        let rate = max(now.speed, 0.1)
        let start = now.capturedAt.addingTimeInterval(-episode.position / rate)
        let end = start.addingTimeInterval(max(episode.duration, 1) / rate)
        VStack(spacing: 2) {
            if now.isPlaying, episode.duration > 0, end > .now {
                ProgressView(timerInterval: start...end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                Text(timerInterval: Date.now...end, countsDown: true)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: episode.duration > 0 ? min(episode.position / episode.duration, 1) : 0)
                Text(Duration.seconds(max(episode.duration - episode.position, 0)).formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
