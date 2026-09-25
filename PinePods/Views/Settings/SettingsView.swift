import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LibraryStore.self) private var library
    @Environment(AudioPlayerController.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss

    @State private var confirmLogout = false
    @State private var confirmRemoveDownloads = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Text(session.username.first.map { String($0).uppercased() } ?? "P")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(
                                LinearGradient(
                                    colors: [Theme.accent.opacity(0.7), Theme.accent],
                                    startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.username.isEmpty ? "Listener" : session.username)
                                .font(.headline)
                            Text(serverHost)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Picker(selection: Binding(
                        get: { settings.playbackSpeed },
                        set: {
                            settings.playbackSpeed = $0
                            player.setSpeed($0)
                        }
                    )) {
                        ForEach(PlaybackSpeed.options, id: \.self) { speed in
                            Text(PlaybackSpeed.label(speed)).tag(speed)
                        }
                    } label: {
                        Label("Default Speed", systemImage: "gauge.with.dots.needle.67percent")
                    }

                    Picker(selection: Binding(
                        get: { settings.skipForwardSeconds },
                        set: {
                            settings.skipForwardSeconds = $0
                            player.updateSkipIntervals()
                        }
                    )) {
                        ForEach(SkipSymbol.intervals, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    } label: {
                        Label("Skip Forward", systemImage: SkipSymbol.forward(settings.skipForwardSeconds))
                    }

                    Picker(selection: Binding(
                        get: { settings.skipBackwardSeconds },
                        set: {
                            settings.skipBackwardSeconds = $0
                            player.updateSkipIntervals()
                        }
                    )) {
                        ForEach(SkipSymbol.intervals, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    } label: {
                        Label("Skip Back", systemImage: SkipSymbol.backward(settings.skipBackwardSeconds))
                    }

                    Toggle(isOn: Binding(
                        get: { settings.skipSilence },
                        set: { player.setSkipSilence($0) }
                    )) {
                        Label("Skip Silence", systemImage: "waveform.path")
                    }

                    Toggle(isOn: Binding(
                        get: { settings.continuePlayback },
                        set: { settings.continuePlayback = $0 }
                    )) {
                        Label("Continue Playing Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Skip Silence speeds through pauses of about two seconds or more. It works with regular podcast files, not live streams.")
                }

                Section {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        LabeledContent {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.accent).frame(width: 12, height: 12)
                                Text(settings.accent.name)
                            }
                        } label: {
                            Label("Appearance", systemImage: "paintpalette")
                        }
                    }
                }

                Section {
                    NavigationLink {
                        AutomationView()
                    } label: {
                        LabeledContent {
                            Text(settings.automationRules.enabledCount == 0
                                ? "Off" : "\(settings.automationRules.enabledCount) on")
                        } label: {
                            Label("Automation", systemImage: "gearshape.2")
                        }
                    }
                } footer: {
                    Text("Rules that download, queue and clean up episodes on a schedule.")
                }

                Section {
                    Picker(selection: Binding(
                        get: { settings.keepQueuedDownloaded },
                        set: {
                            settings.keepQueuedDownloaded = $0
                            downloads.syncQueueDownloads(library.queuedEpisodes)
                        }
                    )) {
                        Text("Off").tag(0)
                        ForEach([1, 2, 3, 5, 10], id: \.self) { count in
                            Text("Next \(count)").tag(count)
                        }
                    } label: {
                        Label("Keep Queue Downloaded", systemImage: "arrow.down.circle")
                    }

                    Toggle(isOn: Binding(
                        get: { settings.downloadOverCellular },
                        set: { settings.downloadOverCellular = $0 }
                    )) {
                        Label("Download Over Cellular", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    Picker(selection: Binding(
                        get: { settings.downloadLimitGB },
                        set: { settings.downloadLimitGB = $0 }
                    )) {
                        ForEach([1, 2, 5, 10, 20], id: \.self) { gigabytes in
                            Text("\(gigabytes) GB").tag(gigabytes)
                        }
                        Text("No Limit").tag(0)
                    } label: {
                        Label("Storage Limit", systemImage: "internaldrive")
                    }

                    LabeledContent {
                        Text(downloads.usedBytes.formatted(.byteCount(style: .file)))
                    } label: {
                        Label("Used on iPhone", systemImage: "iphone")
                    }

                    Button("Remove All Downloads", role: .destructive) {
                        confirmRemoveDownloads = true
                    }
                    .disabled(downloads.downloads.isEmpty && downloads.activeEpisodes.isEmpty)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Downloaded episodes play without a connection. The storage limit applies to automatic downloads.")
                }

                Section("Library") {
                    LabeledContent {
                        Text("\(library.podcasts.count)")
                    } label: {
                        Label("Shows", systemImage: "square.stack")
                    }
                    LabeledContent {
                        Text("\(library.serverDownloads.count)")
                    } label: {
                        Label("Server Downloads", systemImage: "arrow.down.circle")
                    }
                }

                Section("Server") {
                    LabeledContent("Address", value: session.server)
                    LabeledContent("User ID", value: "\(session.userId)")
                }

                Section {
                    Button("Log Out", role: .destructive) {
                        confirmLogout = true
                    }
                    .frame(maxWidth: .infinity)
                } footer: {
                    VStack(spacing: 4) {
                        Text("Kural \(appVersion)")
                        Text("An unofficial client for PinePods servers.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
            .confirmationDialog("Remove all downloads from this iPhone?", isPresented: $confirmRemoveDownloads, titleVisibility: .visible) {
                Button("Remove All", role: .destructive) { downloads.deleteAll() }
            }
            .confirmationDialog("Log out of \(serverHost)?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Log Out", role: .destructive) {
                    player.stop()
                    dismiss()
                    session.logout()
                }
            } message: {
                Text("Playback stops and you'll need your password to sign back in.")
            }
        }
    }

    private var serverHost: String {
        URL(string: session.server)?.host() ?? session.server
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
