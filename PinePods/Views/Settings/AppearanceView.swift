import SwiftUI

struct AppearanceView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var selectedIcon = AppIcon.current

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(AccentTheme.allCases) { theme in
                        Button {
                            withAnimation(.snappy) { settings.accent = theme }
                            if settings.iconFollowsAccent { selectedIcon = theme }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(theme.color.gradient)
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        if settings.accent == theme {
                                            Image(systemName: "checkmark")
                                                .font(.headline.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay {
                                        Circle().strokeBorder(.primary.opacity(settings.accent == theme ? 0.35 : 0), lineWidth: 2)
                                            .padding(-4)
                                    }
                                Text(theme.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.name)
                        .accessibilityAddTraits(settings.accent == theme ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Accent Color")
            }

            Section {
                Toggle("Match App Icon to Accent", isOn: $settings.iconFollowsAccent)
                    .onChange(of: settings.iconFollowsAccent) { _, follows in
                        if follows { selectedIcon = settings.accent }
                    }

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(AccentTheme.allCases) { theme in
                        Button {
                            selectedIcon = theme
                            AppIcon.apply(theme)
                        } label: {
                            Image("IconPreview-\(theme.name)")
                                .resizable()
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .strokeBorder(Theme.accent, lineWidth: selectedIcon == theme ? 2.5 : 0)
                                        .padding(-4)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(theme.name) icon")
                        .accessibilityAddTraits(selectedIcon == theme ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
                .disabled(settings.iconFollowsAccent)
                .opacity(settings.iconFollowsAccent ? 0.45 : 1)
            } header: {
                Text("App Icon")
            } footer: {
                Text("iOS confirms each icon change with a short alert.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
