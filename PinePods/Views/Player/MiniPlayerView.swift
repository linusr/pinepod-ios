import SwiftUI

/// Tab bar accessory: compact now-playing strip. Drops the podcast name and
/// skip button when the tab bar is minimized to the inline placement.
struct MiniPlayerView: View {
    @Environment(AudioPlayerController.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    let onExpand: () -> Void

    var body: some View {
        if let episode = player.currentEpisode {
            HStack(spacing: 10) {
                ArtworkImage(episode.episodeArtwork, cornerRadius: 7)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 0) {
                    Text(episode.episodeTitle)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    if placement != .inline {
                        Text(episode.podcastName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await player.playOrToggle(episode) }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.secondary.opacity(0.3), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: progressFraction)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        if player.isBuffering && !player.isPlaying {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                if placement != .inline {
                    Button {
                        player.fastForward(milliseconds: settings.skipForwardSeconds * 1000)
                    } label: {
                        Image(systemName: SkipSymbol.forward(settings.skipForwardSeconds))
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Skip forward")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens Now Playing")
        }
    }

    private var progressFraction: Double {
        guard player.durationSeconds > 0 else { return 0 }
        return min(player.positionSeconds / player.durationSeconds, 1)
    }
}
