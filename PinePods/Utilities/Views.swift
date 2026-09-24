import SwiftUI

/// Remote artwork via `ImagePipeline`, with a branded placeholder while
/// loading or on failure. Size it with `.frame`.
struct ArtworkImage: View {
    let url: String?
    var cornerRadius: CGFloat

    @State private var image: UIImage?

    init(_ url: String?, cornerRadius: CGFloat = 12) {
        self.url = url
        self.cornerRadius = cornerRadius
        _image = State(initialValue: ImagePipeline.shared.cachedImage(for: url))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ArtworkPlaceholder()
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
            .accessibilityHidden(true)
            .task(id: url) {
                if let cached = ImagePipeline.shared.cachedImage(for: url) {
                    image = cached
                    return
                }
                image = nil
                let loaded = await ImagePipeline.shared.image(for: url)
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

struct ArtworkPlaceholder: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [PineGreen.opacity(0.55), PineGreen],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "waveform")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .frame(width: geo.size.width * 0.36)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Gradient background tinted by the artwork's average color.
struct ArtworkBackdrop: View {
    enum Style {
        /// Soft wash that fades out, for the top of detail pages.
        case header
        /// Solid tinted fill for cards carrying white text.
        case card
        /// Full-bleed dark gradient for the Now Playing screen.
        case fullScreen
    }

    let url: String?
    var style: Style

    @State private var tint: Color?

    init(_ url: String?, style: Style) {
        self.url = url
        self.style = style
        _tint = State(initialValue: ImagePipeline.shared.cachedTint(for: url))
    }

    var body: some View {
        let base = tint ?? PineGreen.mix(with: .black, by: 0.35)
        Group {
            switch style {
            case .header:
                LinearGradient(
                    colors: [base.opacity(0.6), base.opacity(0.22), .clear],
                    startPoint: .top, endPoint: .bottom)
            case .card:
                LinearGradient(
                    colors: [base, base.mix(with: .black, by: 0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            case .fullScreen:
                LinearGradient(
                    colors: [base, base.mix(with: .black, by: 0.55), base.mix(with: .black, by: 0.85)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: tint)
        .task(id: url) {
            if let loaded = await ImagePipeline.shared.tint(for: url) {
                tint = loaded
            }
        }
    }
}

/// Thin capsule progress indicator drawn in the current foreground style.
struct ProgressCapsule: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().opacity(0.3)
                Capsule().frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
    }
}

/// Play/pause pill for episode rows and cards: plays without navigating and
/// shows remaining time, played state, or live progress for the current episode.
struct EpisodePlayButton: View {
    enum Style { case tinted, onColor }

    @Environment(AudioPlayerController.self) private var player

    let episode: PinepodsEpisode
    var style: Style = .tinted

    var body: some View {
        let isCurrent = player.currentEpisode?.episodeId == episode.episodeId
        let isPlaying = isCurrent && player.isPlaying

        Button {
            Task { await player.playOrToggle(episode) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                if let fraction = progressFraction(isCurrent: isCurrent) {
                    ProgressCapsule(fraction: fraction)
                        .frame(width: 26, height: 4)
                }
                Text(label(isCurrent: isCurrent))
                    .contentTransition(.numericText())
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(style == .tinted ? PineGreen : .white)
            .background(
                style == .tinted ? PineGreen.opacity(0.14) : .white.opacity(0.22),
                in: Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: isPlaying)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private func progressFraction(isCurrent: Bool) -> Double? {
        if isCurrent, player.durationSeconds > 0, player.positionSeconds > 0 {
            return player.positionSeconds / player.durationSeconds
        }
        if !isCurrent, !episode.completed, episode.progressPercentage > 0 {
            return episode.progressPercentage / 100
        }
        return nil
    }

    private func label(isCurrent: Bool) -> String {
        if isCurrent, player.durationSeconds > 0 {
            let remaining = Int(player.durationSeconds - player.positionSeconds)
            return "\(Formatters.compactDuration(seconds: remaining)) left"
        }
        if episode.completed { return "Played" }
        if episode.progressPercentage > 0, let remaining = episode.remainingSeconds {
            return "\(Formatters.compactDuration(seconds: remaining)) left"
        }
        return episode.episodeDuration > 0 ? Formatters.compactDuration(seconds: episode.episodeDuration) : "Play"
    }
}

/// Queue, save, played and download actions shared by every episode list.
struct EpisodeActionsModifier: ViewModifier {
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads

    let episode: PinepodsEpisode
    let swipes: Bool

    func body(content: Content) -> some View {
        let queued = library.isQueued(episode.episodeId)
        content
            .navigationLinkIndicatorVisibility(.hidden)
            .contextMenu {
                Section {
                    Button {
                        Task { await library.playNext(episode) }
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button {
                        Task {
                            if queued {
                                await library.removeFromQueue(episode)
                            } else {
                                await library.addToQueue(episode)
                            }
                        }
                    } label: {
                        Label(queued ? "Remove from Queue" : "Add to Queue",
                              systemImage: queued ? "minus.circle" : "text.line.last.and.arrowtriangle.forward")
                    }
                }
                Section {
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
                }
                Section {
                    if downloads.isDownloading(episode.episodeId) {
                        Button(role: .destructive) {
                            downloads.cancel(episode.episodeId)
                        } label: {
                            Label("Cancel Download", systemImage: "xmark.circle")
                        }
                    } else if downloads.isDownloaded(episode.episodeId) {
                        Button(role: .destructive) {
                            downloads.delete(episode.episodeId)
                        } label: {
                            Label("Remove from iPhone", systemImage: "iphone.slash")
                        }
                    } else {
                        Button {
                            downloads.download(episode)
                        } label: {
                            Label("Download to iPhone", systemImage: "arrow.down.circle")
                        }
                    }
                    if episode.downloaded {
                        Button(role: .destructive) {
                            Task { await library.deleteDownload(episode: episode) }
                        } label: {
                            Label("Remove from Server", systemImage: "externaldrive.badge.minus")
                        }
                    } else {
                        Button {
                            Task { await library.startDownload(episode: episode) }
                        } label: {
                            Label("Download to Server", systemImage: "externaldrive.badge.plus")
                        }
                    }
                }
            }
            .swipeActions(edge: .leading) {
                if swipes {
                    Button {
                        Task {
                            if queued {
                                await library.removeFromQueue(episode)
                            } else {
                                await library.addToQueue(episode)
                            }
                        }
                    } label: {
                        Label(queued ? "Unqueue" : "Queue",
                              systemImage: queued ? "minus.circle.fill" : "text.line.last.and.arrowtriangle.forward")
                    }
                    .tint(.orange)
                    Button {
                        Task { await library.setSaved(episode, !episode.saved) }
                    } label: {
                        Label(
                            episode.saved ? "Unsave" : "Save",
                            systemImage: episode.saved ? "bookmark.slash.fill" : "bookmark.fill")
                    }
                    .tint(PineGreen)
                }
            }
            .swipeActions(edge: .trailing) {
                if swipes {
                    Button {
                        Task { await library.setCompleted(episode, !episode.completed) }
                    } label: {
                        Label(
                            episode.completed ? "Unplayed" : "Played",
                            systemImage: episode.completed ? "circle" : "checkmark.circle.fill")
                    }
                    .tint(.indigo)
                }
            }
    }
}

extension View {
    /// `swipes: false` leaves swipe actions to the caller (e.g. the queue's Remove).
    func episodeActions(_ episode: PinepodsEpisode, swipes: Bool = true) -> some View {
        modifier(EpisodeActionsModifier(episode: episode, swipes: swipes))
    }
}

/// Small circular progress indicator for in-flight downloads.
struct DownloadRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(fraction, 0.03))
                .stroke(PineGreen, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: fraction)
        }
    }
}

/// Section title with an optional trailing accessory.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.weight(.bold))
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

enum HTMLText {
    private static let namedEntities: [String: String] = [
        "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&#39;": "'", "&apos;": "'", "&rsquo;": "’", "&lsquo;": "‘",
        "&rdquo;": "”", "&ldquo;": "“", "&mdash;": "—", "&ndash;": "–",
        "&hellip;": "…",
    ]

    /// HTML show notes to readable plain text: block tags become line breaks,
    /// list items become bullets, entities are decoded.
    static func plainText(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var text = html
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<li[^>]*>", with: "\n• ", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</(p|div|h[1-6]|ul|ol)>", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in namedEntities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = decodeNumericEntities(text)
        return text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\n\\s*\\n\\s*", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Single-paragraph preview; only the leading slice of long HTML is parsed.
    static func preview(_ html: String) -> String {
        let slice = String(html.prefix(700))
            .replacingOccurrences(of: "<[^>]*$", with: "", options: .regularExpression)
        return plainText(slice)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var result = ""
        var remainder = Substring(text)
        while let range = remainder.range(of: "&#[xX]?[0-9a-fA-F]+;", options: .regularExpression) {
            result += remainder[..<range.lowerBound]
            let token = remainder[range].dropFirst(2).dropLast()
            let scalar = token.first == "x" || token.first == "X"
                ? UInt32(token.dropFirst(), radix: 16)
                : UInt32(token)
            if let scalar, let unicode = Unicode.Scalar(scalar) {
                result.append(Character(unicode))
            } else {
                result += remainder[range]
            }
            remainder = remainder[range.upperBound...]
        }
        return result + remainder
    }
}
