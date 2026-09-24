import SwiftUI

struct AutomationView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AutomationEngine.self) private var engine

    @State private var confirmClearOld = false
    @State private var pendingClearDays: Int?

    var body: some View {
        @Bindable var settings = settings
        let rules = settings.automationRules

        Form {
            Section {
                Toggle(isOn: $settings.automationRules.downloadRegular) {
                    Label("Download New Episodes", systemImage: "arrow.down.circle")
                }
                Toggle(isOn: $settings.automationRules.queueRegular) {
                    Label("Add New Episodes to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                if rules.downloadRegular || rules.queueRegular {
                    Picker(selection: $settings.automationRules.regularMinEpisodes) {
                        ForEach(1...5, id: \.self) { Text("\($0) played").tag($0) }
                    } label: {
                        Label("Regular After", systemImage: "repeat")
                    }
                    Picker(selection: $settings.automationRules.regularWindowDays) {
                        Text("2 weeks").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    } label: {
                        Label("Within", systemImage: "calendar")
                    }
                }
            } header: {
                Text("Shows You Play Regularly")
            } footer: {
                Text("A show is regular once you've played \(rules.regularMinEpisodes) of its episodes within \(windowLabel(rules.regularWindowDays)). Episodes from the last week are handled once — removing one from the queue won't bring it back.")
            }

            Section {
                Picker(selection: $settings.automationRules.removePlayedFromPhoneAfterDays) {
                    Text("Never").tag(AutomationRules.never)
                    Text("Right Away").tag(0)
                    Text("After 1 Day").tag(1)
                    Text("After 1 Week").tag(7)
                } label: {
                    Label("Remove from iPhone", systemImage: "iphone")
                }
                Picker(selection: $settings.automationRules.removePlayedFromServerAfterDays) {
                    Text("Never").tag(AutomationRules.never)
                    Text("After 1 Week").tag(7)
                    Text("After 1 Month").tag(30)
                    Text("After 2 Months").tag(60)
                } label: {
                    Label("Remove from Server", systemImage: "externaldrive")
                }
            } header: {
                Text("Played Episodes")
            } footer: {
                Text("Downloads are removed once this long has passed since you finished the episode.")
            }

            Section {
                Picker(selection: Binding(
                    get: { rules.clearUnplayedAfterDays },
                    set: { newValue in
                        // Turning the sweep on can mark a large back catalog played; confirm first.
                        if rules.clearUnplayedAfterDays == AutomationRules.never, newValue != AutomationRules.never {
                            pendingClearDays = newValue
                            confirmClearOld = true
                        } else {
                            settings.automationRules.clearUnplayedAfterDays = newValue
                        }
                    }
                )) {
                    Text("Never").tag(AutomationRules.never)
                    Text("1 Month Old").tag(30)
                    Text("2 Months Old").tag(60)
                    Text("3 Months Old").tag(90)
                } label: {
                    Label("Mark Played When", systemImage: "archivebox")
                }
                Toggle(isOn: $settings.automationRules.keepSaved) {
                    Label("Keep Saved Episodes", systemImage: "bookmark")
                }
            } header: {
                Text("Old Unplayed Episodes")
            } footer: {
                Text("Unplayed episodes published before this are marked played across all your shows, and their downloads are removed. Checked once a day.")
            }

            Section {
                Picker(selection: $settings.automationRules.intervalHours) {
                    Text("Every 6 Hours").tag(6)
                    Text("Every 12 Hours").tag(12)
                    Text("Once a Day").tag(24)
                } label: {
                    Label("Run", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    Task { await engine.run(trigger: .manual) }
                } label: {
                    HStack {
                        Label("Run Now", systemImage: "play.circle")
                        Spacer()
                        if engine.isRunning {
                            ProgressView()
                        }
                    }
                }
                .disabled(engine.isRunning)
                if let lastRun = engine.lastRun {
                    LabeledContent("Last Run", value: lastRun.formatted(.relative(presentation: .named)))
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Runs when you open the app and in the background when iOS allows it. If the server can't be reached, the run is skipped and nothing changes.")
            }

            Section("Activity") {
                if engine.log.isEmpty {
                    Text("No activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(engine.log.prefix(5)) { run in
                        AutomationRunRow(run: run)
                    }
                    if engine.log.count > 5 {
                        NavigationLink("All Activity") {
                            AutomationLogView()
                        }
                    }
                }
            }
        }
        .navigationTitle("Automation")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Mark old unplayed episodes as played?",
            isPresented: $confirmClearOld, titleVisibility: .visible
        ) {
            Button("Turn On") {
                if let pendingClearDays {
                    settings.automationRules.clearUnplayedAfterDays = pendingClearDays
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The first run marks every unplayed episode older than \(windowLabel(pendingClearDays ?? 60)) as played across all your shows, including their back catalogs, and removes their downloads\(rules.keepSaved ? ". Saved episodes are kept." : ".")")
        }
    }

    private func windowLabel(_ days: Int) -> String {
        switch days {
        case 14: "2 weeks"
        case 30: "30 days"
        case 60: "60 days"
        case 90: "90 days"
        default: "\(days) days"
        }
    }
}

struct AutomationRunRow: View {
    let run: AutomationRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(triggerLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = run.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if run.entries.isEmpty {
                Text("Nothing to do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(run.entries) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Label(summary(entry), systemImage: icon(entry.kind))
                            .font(.caption.weight(.medium))
                        Text(entry.titles.joined(separator: " · ") + (entry.count > entry.titles.count ? " …" : ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var triggerLabel: String {
        switch run.trigger {
        case .app: "On open"
        case .background: "Background"
        case .manual: "Run Now"
        }
    }

    private func summary(_ entry: AutomationRun.Entry) -> String {
        let count = "\(entry.count) episode\(entry.count == 1 ? "" : "s")"
        return switch entry.kind {
        case .downloaded: "Downloaded \(count) to iPhone"
        case .queued: "Queued \(count)"
        case .removedFromPhone: "Removed \(count) from iPhone"
        case .removedFromServer: "Removed \(count) from server"
        case .markedPlayed: "Marked \(count) played"
        }
    }

    private func icon(_ kind: AutomationRun.Entry.Kind) -> String {
        switch kind {
        case .downloaded: "arrow.down.circle"
        case .queued: "text.line.last.and.arrowtriangle.forward"
        case .removedFromPhone: "iphone.slash"
        case .removedFromServer: "externaldrive.badge.minus"
        case .markedPlayed: "checkmark.circle"
        }
    }
}

struct AutomationLogView: View {
    @Environment(AutomationEngine.self) private var engine

    var body: some View {
        List {
            ForEach(engine.log) { run in
                AutomationRunRow(run: run)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear", role: .destructive) { engine.clearLog() }
                    .disabled(engine.log.isEmpty)
            }
        }
    }
}
