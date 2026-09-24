import AVKit
import SwiftUI

struct PlayerView: View {
    @Environment(AudioPlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var showNotes = false
    @State private var showQueue = false

    private var episode: PinepodsEpisode? {
        player.currentEpisode ?? router.pendingEpisode
    }

    var body: some View {
        ZStack {
            ArtworkBackdrop(episode?.episodeArtwork, style: .fullScreen)
                .ignoresSafeArea()
            if let episode {
                content(episode)
            } else {
                ProgressView()
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .sheet(isPresented: $showNotes) {
            if let episode {
                ShowNotesSheet(episode: episode)
                    .preferredColorScheme(.dark)
            }
        }
        .sheet(isPresented: $showQueue) {
            NavigationStack {
                QueueView()
            }
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.dark)
        }
        .onChange(of: player.currentEpisode) { old, new in
            if old != nil, new == nil {
                dismiss()
            }
        }
    }

    private func content(_ episode: PinepodsEpisode) -> some View {
        GeometryReader { geo in
            let artworkSize = max(min(geo.size.width - 48, geo.size.height * 0.44), 120)
            VStack(spacing: 0) {
                topBar(episode)

                Spacer(minLength: 16)

                ArtworkImage(episode.episodeArtwork, cornerRadius: 22)
                    .frame(width: artworkSize, height: artworkSize)
                    .scaleEffect(player.isPlaying ? 1 : 0.86)
                    .shadow(
                        color: .black.opacity(player.isPlaying ? 0.45 : 0.25),
                        radius: player.isPlaying ? 30 : 14, y: player.isPlaying ? 16 : 8)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)

                Spacer(minLength: 16)

                titleRow(episode)

                ScrubBar(
                    position: player.positionSeconds,
                    duration: player.durationSeconds,
                    buffered: player.bufferedSeconds
                ) { player.seek(to: $0) }
                .padding(.top, 20)

                statusLine
                    .frame(height: 20)

                transport(episode)
                    .padding(.vertical, 10)

                bottomBar
                    .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Sections

    private func topBar(_ episode: PinepodsEpisode) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")

            Spacer()

            VStack(spacing: 1) {
                Text("NOW PLAYING")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(episode.podcastName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)

            Spacer()

            Menu {
                Button {
                    Task { await library.setSaved(episode, !episode.saved) }
                } label: {
                    Label(
                        episode.saved ? "Remove from Saved" : "Save Episode",
                        systemImage: episode.saved ? "bookmark.slash" : "bookmark")
                }
                Button {
                    Task { await library.setCompleted(episode, !episode.completed) }
                } label: {
                    Label(
                        episode.completed ? "Mark as Unplayed" : "Mark as Played",
                        systemImage: episode.completed ? "circle" : "checkmark.circle")
                }
                Button {
                    showNotes = true
                } label: {
                    Label("Show Notes", systemImage: "text.alignleft")
                }
                Divider()
                Button(role: .destructive) {
                    player.stop()
                } label: {
                    Label("Stop Playback", systemImage: "stop.fill")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("More")
        }
        .padding(.top, 8)
    }

    private func titleRow(_ episode: PinepodsEpisode) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.episodeTitle)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Text(episode.podcastName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await library.setSaved(episode, !episode.saved) }
            } label: {
                Image(systemName: episode.saved ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressableButtonStyle())
            .sensoryFeedback(.success, trigger: episode.saved)
            .accessibilityLabel(episode.saved ? "Remove from Saved" : "Save Episode")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let errorMessage = player.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if player.isBuffering && !player.isPlaying {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Buffering…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func transport(_ episode: PinepodsEpisode) -> some View {
        HStack {
            Spacer()
            SkipButton(symbol: SkipSymbol.backward(settings.skipBackwardSeconds), label: "Skip back") {
                player.rewind(milliseconds: settings.skipBackwardSeconds * 1000)
            }
            Spacer()
            Button {
                Task { await player.playOrToggle(episode) }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 54))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .frame(width: 92, height: 92)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.85))
            .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            SkipButton(symbol: SkipSymbol.forward(settings.skipForwardSeconds), label: "Skip forward") {
                player.fastForward(milliseconds: settings.skipForwardSeconds * 1000)
            }
            Spacer()
        }
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        HStack {
            Menu {
                Toggle(isOn: Binding(
                    get: { settings.skipSilence },
                    set: { player.setSkipSilence($0) }
                )) {
                    Label("Skip Silence", systemImage: "waveform.path")
                }
                Picker("Playback Speed", selection: Binding(
                    get: { player.speed },
                    set: { player.setSpeed($0) }
                )) {
                    ForEach(PlaybackSpeed.options, id: \.self) { speed in
                        Text(PlaybackSpeed.label(speed)).tag(speed)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(PlaybackSpeed.label(player.speed))
                    if settings.skipSilence {
                        Image(systemName: "waveform.path")
                            .font(.caption.weight(.bold))
                    }
                }
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(minWidth: 40, minHeight: 22)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Playback speed")
            .accessibilityValue(settings.skipSilence
                ? "\(PlaybackSpeed.label(player.speed)), skipping silence"
                : PlaybackSpeed.label(player.speed))

            Spacer()

            RoutePickerButton()
                .frame(width: 44, height: 44)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    showNotes = true
                } label: {
                    Image(systemName: "text.alignleft")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 22, minHeight: 22)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Show Notes")

                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 22, minHeight: 22)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Up Next")
            }
        }
    }
}

// MARK: - Components

private struct SkipButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .regular))
                .symbolEffect(.bounce, value: taps)
                .frame(width: 64, height: 64)
        }
        .buttonStyle(PressableButtonStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel(label)
    }
}

/// Capsule scrubber that thickens while dragging and seeks on release.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    let buffered: Double
    let onSeek: (Double) -> Void

    @State private var dragPosition: Double?

    private var isDragging: Bool { dragPosition != nil }
    private var shownPosition: Double { dragPosition ?? position }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white.opacity(0.22))
                        .frame(width: width * fraction(buffered))
                    Capsule().fill(.white)
                        .frame(width: width * fraction(shownPosition))
                }
                .frame(height: isDragging ? 12 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            dragPosition = min(max(value.location.x / width, 0), 1) * duration
                        }
                        .onEnded { _ in
                            if let dragPosition { onSeek(dragPosition) }
                            dragPosition = nil
                        }
                )
            }
            .frame(height: 24)
            .animation(.spring(duration: 0.25), value: isDragging)

            HStack {
                Text(Formatters.duration(seconds: Int(shownPosition)))
                Spacer()
                Text("-" + Formatters.duration(seconds: max(Int(duration - shownPosition), 0)))
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(isDragging ? 0.95 : 0.6))
        }
        .sensoryFeedback(.selection, trigger: isDragging)
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { position }, set: { onSeek($0) }),
                in: 0...max(duration, 1)
            ) {
                Text("Playback position")
            }
        }
    }

    private func fraction(_ value: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(value / duration, 0), 1)
    }
}

struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(PineGreen)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct ShowNotesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let episode: PinepodsEpisode

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ArtworkImage(episode.episodeArtwork, cornerRadius: 10)
                            .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(episode.episodeTitle)
                                .font(.headline)
                                .lineLimit(2)
                            Text(episode.podcastName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    let notes = HTMLText.plainText(episode.episodeDescription)
                    Text(notes.isEmpty ? "No show notes for this episode." : notes)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                .padding(20)
            }
            .navigationTitle("Show Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
