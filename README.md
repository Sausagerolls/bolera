# Bolera

A native music client for [Jellyfin](https://jellyfin.org), built for macOS and iOS.

Bolera is a fully native SwiftUI app — no Catalyst, no web wrappers — that turns a self-hosted Jellyfin server into a polished, day-to-day music player. Daily themed mixes, mood-based Make-a-Mix, a real 10-band EQ, time-synced lyrics (auto-fetched when your server has none), Last.fm-powered similar artists and bios, offline downloads with automatic container detection, CarPlay, and a sidebar / now-playing experience designed for music listeners.

> **Status:** Submitted to the App Store and Mac App Store — launching soon. Source is published for transparency and community feedback.

## Project layout

```
Bolera/                 # iOS app target (SwiftUI)
Bolera-mac/             # macOS app target (SwiftUI, native — not Catalyst)
Bolera/CarPlay/         # CarPlay scene + templates (iOS)
BoleraCore/             # Shared Swift Package: networking, audio, models, stores
Bolera.xcodeproj/       # Combined Xcode project (both targets + the package)
```

The two app targets share **BoleraCore**, a local Swift package containing:

- `Networking/` — `JellyfinClient`, `AuthManager`
- `Audio/` — `AudioPlayer` (AVPlayer-backed), `AudioProcessor` (10-band biquad EQ via `MTAudioProcessingTap`)
- `Services/` — `LastFmService` (scrobble + similar-artist lookups), `LyricsService` (server lyrics with LRCLIB fallback), `SleepTimer`
- `Library/` — `LibraryStore`, `DownloadManager`, `DailyPlaylistStore`, `PinnedItemsStore`
- `Pro/` — `ProEntitlementStore` (StoreKit 2), library-visibility / ignored-track toggles, iCloud KVS sync
- `Models/` — `BaseItem` + Jellyfin response decoders

## Build

Requirements:

- macOS 14 / Xcode 16 or newer
- iOS 18 deployment target (iPhone)
- macOS 14 deployment target (Mac)
- A Jellyfin 10.9+ server to actually sign in

Open `Bolera.xcodeproj` and pick the **Bolera** (iOS) or **Bolera-mac** scheme.

CLI build for the Mac target:

```bash
xcodebuild -project Bolera.xcodeproj \
           -scheme Bolera-mac \
           -destination 'platform=macOS' \
           -configuration Debug \
           build
```

## Last.fm integration

Last.fm powers the similar-artists rail on the artist detail page, full artist bios, the smarter daily-mix grouping, and optional scrobbling.

To enable it:

1. Register an app at [last.fm/api/account/create](https://www.last.fm/api/account/create).
2. Copy the template into a local-only secrets file:

   ```bash
   cp BoleraCore/Sources/BoleraCore/Services/LastFmSecrets.swift.example \
      BoleraCore/Sources/BoleraCore/Services/LastFmSecrets.swift
   ```

3. Paste your API Key + Shared Secret into the new file. It's gitignored so credentials stay on your machine.

Once filled in, users sign in to Last.fm with just their last.fm username and password — no per-user API keys required.

If both values remain as `YOUR_…` placeholders, all Last.fm features (Similar Artists, bios, smarter daily mixes, scrobbling, mood mixes) simply turn themselves off at runtime.

## Pro

A one-time `$4.99` non-consumable In-App Purchase unlocks:

- Full 10-band EQ
- Library-visibility toggles (hide e.g. a Christmas library)
- Ignored-tracks list (auto-skip the cursed ones)
- Sidebar pinning of artists and albums
- iCloud KVS sync of the above across devices

CarPlay is supported on iOS. Pro state syncs via iCloud KVS so a purchase on iOS unlocks on Mac and vice versa.

## License

No license is granted. **Source is published for transparency only.**

This project is _source-available, not open-source._ You are welcome to read the code, file issues, suggest improvements, and submit pull requests. You are **not** granted permission to redistribute, fork into a competing product, or repackage this software. All rights reserved by the copyright holder.

If you want to use part of this project under different terms, [get in touch](mailto:contact@giantmushroom.studio).

## Contributing

Issues and PRs welcome. Please don't submit unrelated drive-by changes — open an issue first if a change is non-trivial.

## Contact

[contact@giantmushroom.studio](mailto:contact@giantmushroom.studio) · [giantmushroom.studio/bolera](https://giantmushroom.studio/bolera)
