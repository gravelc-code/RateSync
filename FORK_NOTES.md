# Fork notes

This is a modified fork of [BiKing567/RateSync](https://github.com/BiKing567/RateSync)
(itself derived from [vincentneo/LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher)),
distributed under the same licence, GPL-3.0. Modified September 2026. Everything
not listed here is upstream's work.

## What differs from upstream

### 1. Apple Music: use the current track's sample rate before decoder logs

Upstream resolves Apple Music's rate from the newest
`ACAppleLosslessDecoder.cpp … Input format` line that Music writes to the unified
log. Music keeps more than one ALAC decoder alive: roughly a second after a track
starts it creates another to pre-buffer the *next* track for gapless playback.
Those log lines carry no track identity, so "newest line" is often the next
track's format, and the output device is switched to the wrong rate mid-song.

Observed on macOS 27.2 with a USB DAC, playing Hi-Res Lossless:

| Playing track | Device was set to |
|---|---|
| 96 kHz | 48 kHz |
| 176.4 kHz (after first switching correctly) | 48 kHz |
| 48 kHz (no switch needed) | 44.1 kHz |

Each wrong switch also costs an audible dropout. Example, one track start:

```
21:21:01.687  ACAppleLosslessDecoder  96000 Hz from 24-bit source   <- playing
21:21:02.466  ACAppleLosslessDecoder  48000 Hz from 24-bit source   <- next track, pre-buffered
```

The fork asks Music directly (`sample rate of current track`, the AppleScript call
upstream already uses as a last resort) before consulting the logs, because that
answer is about the playing track by definition. Streamed tracks report
`missing value` for their first few seconds, so the fork waits up to 6 s after a
track change before falling back to the log chain; falling back sooner would
switch wrongly and then correct itself, i.e. two dropouts instead of one. Other
players are unaffected. See `runLogChain` in `Quality/OutputDevices.swift` and
`RateSource.appleMusicCurrentTrack` in `Quality/RateSwitchingPolicy.swift`.

Known gap: a track for which Music never reports a rate still goes through the
log chain and can still be misread.

### 2. Sparkle auto-update is disabled

`SUFeedURL` is removed and the updater is not started. Upstream's feed would
replace a build of this fork with upstream's release, silently dropping change 1.
Update by pulling and rebuilding instead.

## Building

Build with `archive`, or pass `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` to a plain
`build`. Otherwise Xcode injects the debug entitlement
`com.apple.security.get-task-allow` into the Release product, which lets any
local process attach to the app.

```sh
xcodebuild -project Quality.xcodeproj -scheme RateSync -configuration Release \
  DEVELOPMENT_TEAM="<your team id>" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="<your Developer ID Application identity>" \
  PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build
```
