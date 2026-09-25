# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Kural** (குரல், "voice"): an unofficial native SwiftUI iOS client for self-hosted [PinePods](https://github.com/madeofpendletonwool/PinePods) podcast servers. It is a port of the upstream Flutter client, and much of its behavior is written to match that client. Only the display name, icon and UI copy say "Kural"; the Xcode target, scheme, bundle ID (`me.4vr.pinepods`) and log prefix still say PinePods. User-facing text mentions PinePods only to name the server it connects to.

## Commands

```sh
# Build for the simulator (Swift 6; no SPM dependencies)
xcodebuild -project PinePods.xcodeproj -scheme PinePods -destination 'generic/platform=iOS Simulator' build

# Unit tests (Swift Testing, target PinePodsTests, hosted in the app); needs an iOS 27 simulator
xcodebuild test -project PinePods.xcodeproj -scheme PinePods -destination 'platform=iOS Simulator,name=<iOS 27 device>'
# One suite or test:
xcodebuild test ... -only-testing:PinePodsTests/AutomationPlannerTests
xcodebuild test ... -only-testing:PinePodsTests/AutomationPlannerTests/oldUnplayedEpisodesAreMarkedAndCleaned()

# Check every endpoint the client calls against a server's OpenAPI spec
python3 scripts/validate_api.py <server-url>
```

Tests cover pure logic: the automation planner, models and parsing, formatters, HTML cleanup, URL validation and redaction, and the Keychain. Views, the player and networking aren't unit-tested; use demo mode to exercise them.

Source groups are `fileSystemSynchronizedGroups`: new `.swift` files are picked up automatically without editing `project.pbxproj`.

**Targets**

| Target | Folders | Notes |
|---|---|---|
| `PinePods` (the app) | `PinePods/`, `Shared/` | Built with the `KURAL_APP` compilation condition |
| `KuralWidgets` (WidgetKit extension, embedded in the app) | `KuralWidgets/`, `Shared/` | `Info.plist` is excluded from its sources |
| `PinePodsTests` | `PinePodsTests/` | Hosted in the app |

Both the app and the widget carry the App Group `group.me.4vr.pinepods` (`Entitlements/`). The project file is hand-authored with readable `AA…` object IDs; to add a target, follow the existing entries.

## Upstream reference

The upstream PinePods repo is checked out next to this one at `../PinePods`:

- `../PinePods/mobile/` — Flutter client; the behavioral reference this app ports (look for `PinepodsService` and the audio/settings services).
- `../PinePods/rust-api/src/handlers/` — backend handlers. Several endpoints return untyped `serde_json::Value`, so their response shape is only verifiable here, not from the OpenAPI spec.

## Architecture

**State: four `@MainActor @Observable` singletons**, created in `PinePodsApp` and injected with `.environment(...)`:

| Store | Role |
|---|---|
| `SessionStore` | Server URL, API key, user id, username in `UserDefaults`. `isLoggedIn` gates `RootView` between `LoginView` and `RootTabView`. Vends an `APIClient` via `client`. |
| `LibraryStore` | All server-backed library data (podcasts, home overview, paginated feed, per-podcast episode cache, server downloads, download tasks). Polls `/api/tasks/user/{id}` every 4 s while any task is active. `updateEpisode(_:)` patches an episode into every cached collection so rows update without refetching. |
| `AudioPlayerController` | `AVPlayer` + audio session + Now Playing / remote commands + server progress sync. |
| `SettingsStore` | Playback, queue and download preferences in `UserDefaults`. |
| `DownloadManager` | Episode files on the phone (`Application Support/Kural/Media`), fetched in a background `URLSession` (the app delegate forwards its relaunch events). The player prefers a local file over streaming. It also keeps the first N queue entries downloaded. |
| `AutomationEngine` | User rules (`SettingsStore.automationRules`) run with no approval step: when the app becomes active if the interval has passed, from background app refresh (`BGTaskSchedulerPermittedIdentifiers`), or via Run Now. It gathers history, feed, queue and downloads, gets a plan from the pure `AutomationPlanner`, applies it with the bulk endpoints, and keeps an activity log. It gathers everything before acting, so an unreachable server means nothing changes. |
| `WidgetPublisher` (app only) | On discrete changes (episode, play/pause, seek, queue, accent), writes `WidgetSnapshot` plus 300 px artwork thumbnails into the App Group and reloads the widget timeline. Widgets can't load remote images or reach app data, and they draw live progress from timer intervals, so nothing needs publishing mid-playback. |
| `SyncOutbox` | Durable, ordered queue of position and completion updates. Offline updates are sent when `NWPathMonitor` reports a connection or the app returns to the foreground. It also remembers the last position per episode, so resume uses the later of the server's and the device's position. |

Stores reach each other through `.shared` (e.g. `LibraryStore` reads `SessionStore.shared`), not through injection.

**Networking (`Networking/APIClient.swift`)** — a `Sendable` value type built from `server` + `apiKey`, sharing one static `URLSession` (15 s timeouts). Login is Basic-auth to `/api/data/get_key` (may return an MFA challenge, completed via `verify_mfa_and_get_key`); every later request sends the `Api-Key` header. User id comes from `/api/data/get_user`. Responses are parsed with `JSONSerialization` into `[String: Any]`, not `Codable`.

**Model parsing (`Utilities/JSON.swift`, `Models/Models.swift`)** — models are built with `init(json:)` using the `JSON.str/int/bool/...` helpers, which take several candidate keys because the server mixes snake_case and PascalCase (and numbers-as-strings) across endpoints. Keep that tolerance when adding fields.

**Adding or changing an endpoint:** update `APIClient`, then add or adjust its row in `CHECKS` in `scripts/validate_api.py` and run the script.

**Playback (`Audio/`)**
- Most episodes stream from their original media URL; downloaded and YouTube episodes stream from `/api/data/stream/{id}` with the API key in the query string (`APIClient.streamURL`).
- Server sync mirrors the Flutter client: position every 15 s with a 2 s delta threshold, listen time every 60 s, immediate sync on pause/seek, and completion marking at end of item.
- **Queue:** `LibraryStore` holds the queue and saves a copy to disk so it works offline. "Play Next" is add-then-`reorder_queue`, because 0.9.0 has no `queue_bump`. When an episode finishes, the server removes it from the queue; the app mirrors that and starts `nextInQueue` (setting "Continue Playing Queue").
- `APIClient.post` returns false for 4xx and throws for transport errors and 5xx. The outbox relies on this: it drops rejected updates and retries unreachable ones.
- Positions are saved with `record_listen_duration`, which stores seconds but only ever raises the stored value. Never use `record_podcast_history`: the backend stores its `episode_pos` × 100, which makes the next resume jump 100× further. A saved position past the episode's end is treated as corrupt; the player starts from 0 and resets it with `mark_episode_uncompleted`.
- Seeking far ahead in a server-streamed episode (downloaded or YouTube, `/api/data/stream/{id}`) needs HTTP range support. Upstream `stream_episode` drops the `Range` header before `ServeFile`, so only already-buffered positions are reachable. The fix is local in `../PinePods/rust-api/src/handlers/podcasts.rs` and needs a server deploy.
- If AVFoundation's estimated duration differs from the feed's by more than 10% (VBR MP3 without a Xing header), the asset is reloaded with `AVURLAssetPreferPreciseDurationAndTimingKey`.
- The audio session uses `.playback` / `.spokenAudio` / `.longFormAudio` policy. That policy rejects category options (the legacy Bluetooth options fail with OSStatus -50 on iOS 26+). Activation runs lazily on a detached task, because a synchronous `setActive` on the main thread can stall the UI.
- Rate changes go through `applyRate()`. It uses `player.defaultRate` so resume keeps the chosen speed, and it only changes the rate while playing, so a speed change never starts playback.
- Skip Silence (`SilenceDetector`, setting `skip_silence`) uses an `MTAudioProcessingTap` on the item's audio mix to find stretches under -40 dBFS lasting at least 1 s. The player runs at up to 4× through them. The tap runs about 1 s ahead of playback, so transitions carry an item time and are applied with a boundary time observer; normal speed returns 0.25 s before speech. In practice only pauses of about 2 s or more get sped up. A lower minimum flipped the rate for fractions of a second, which was audible and saved almost nothing: about 3 s over a 62-minute talk show.
- Interruptions (calls, Siri, other apps) pause playback. When iOS 27 sends `ResumptionRecommendationMessage.shouldResume` and audio was playing beforehand, playback resumes; the session is reactivated first. Any explicit play/pause/stop in between cancels the resume. Taps don't run on HLS.
- **Widget buttons** are `AudioPlaybackIntent`s in `Shared/PlaybackIntents.swift`. iOS runs `perform()` in the app's process, launching it in the background if needed; the `#if KURAL_APP` body calls `PlaybackBridge`, which falls back to the last played episode (`AudioPlayerController.lastEpisode`, kept on disk) and then Up Next. Tapping a widget opens `kural://nowplaying`.
- `NowPlayingManager` owns `MPNowPlayingInfoCenter` and artwork; `RemoteCommandManager` owns the `MPRemoteCommandCenter` handlers.

**UI**
- `RootTabView`: Home, Feed, Library, Downloads, and a Search tab (`role: .search`, filters in-memory shows and episodes). The mini player sits in `tabViewBottomAccessory(isEnabled:)` and zooms into the full-screen `PlayerView`. Settings is a sheet opened from the toolbar `AccountButton`.
- `AppRouter` (environment, `.shared`) owns tab selection and the player/settings presentation. Open Now Playing with `router.presentPlayer(for:)` rather than a local `fullScreenCover`.
- Shared building blocks live in `Utilities/`:
  - `ArtworkImage`: artwork loaded through `ImagePipeline`, a cached and downsampled loader. Don't use `AsyncImage`.
  - `ArtworkBackdrop`: gradients tinted with the artwork's average color.
  - `EpisodePlayButton`: play/pause pill for rows and cards.
  - `.episodeActions(_:)`: context menu and swipe actions for save, played and download.
  - `Theme.swift`: `AccentTheme` (ten accents), `Theme.accent` (the user's choice, read from `SettingsStore`, so views re-render when it changes; never hard-code a color), `SkipSymbol` (SF Symbols only has numbered skip glyphs for 5/10/15/30/45/60/75/90 s) and `PlaybackSpeed`.
- Each accent except Pine has an alternate icon set, `AppIcon-<Name>`, with light, dark and tinted images, plus an `IconPreview-<Name>` image for Settings. The build setting `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS` includes them in the build. `AppIcon.apply(_:)` switches icons; iOS shows its own confirmation alert.
- Save and played toggles go through `LibraryStore.setSaved` / `setCompleted`, which update every cache and the player's current episode.

**Demo mode (DEBUG only)** — to work on the UI without a server, launch with `-PinePodsDemo`. It fills the stores with sample data from `Debug/DemoMode.swift`. Add `-PinePodsDemoScreen <home|feed|library|downloads|search|player|settings>` to open a specific screen. With `-PinePodsDemoMedia <url>`, every episode points at that audio file and a stand-in session is signed in, so playback, downloads and queue advancing really run; API calls fail harmlessly against that host. For example:

```sh
xcrun simctl launch <udid> me.4vr.pinepods -PinePodsDemo -PinePodsDemoScreen player
xcrun simctl io <udid> screenshot out.png
```

Simulators need the iOS 27 runtime. `xcrun simctl create "<name>" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0` creates one.

## Project notes

- Minimum deployment target is iOS 27. Use iOS 26+ SwiftUI APIs (Liquid Glass, `Tab`, `tabViewBottomAccessory`) directly; no `#available` fallbacks.
- `Info.plist` is hand-maintained (`GENERATE_INFOPLIST_FILE = NO`). It allows arbitrary loads (ATS off) and declares local-network usage, because servers are often plain-HTTP on a LAN. Background modes are `audio` and `fetch` only; declare nothing unused, since App Review checks.
- `Resources/PrivacyInfo.xcprivacy` declares UserDefaults use (reason CA92.1) and no tracking or data collection. Update it when adding required-reason APIs (file timestamps, disk space, boot time).
- The API key lives in the Keychain (`Utilities/Keychain.swift`, after-first-unlock so background refresh works); keys saved by older builds in UserDefaults are migrated on launch. Never log URLs that carry it: use `APIClient.redacted(_:)`.
- Build every URL from user input with `APIClient.endpoint(_:_:)`, which validates instead of force-unwrapping.
- Demo mode and its store hooks are `#if DEBUG`; Release and App Store builds don't contain them.
- `build/` is local build output, not source.
