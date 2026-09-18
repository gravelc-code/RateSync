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

### 2. Apple Music: switch just before the track ends, not 1-2 s into the next one

A rate change always costs a short dropout while the device re-clocks. Upstream
(and change 1 on its own) can only act once the new track is already playing, so
the dropout lands a second or two into the song.

The next-track decoder line that caused the bug in change 1 is, read the other
way round, a forecast: once the playing track's rate comes from Music itself, the
newest decoder format logged since the track began is the NEXT track's. The fork
remembers it, and when Music reports under 6 s left it schedules the switch for
0.6 s before the end, re-reading the exact position from Music when the timer
fires so that a seek or pause since arming can never cause a mid-song switch.
It then holds the new rate until the track changes (or 6 s pass). Consecutive
tracks at different rates come from different masters, so no gapless continuity
is lost, and the final half second of a song is almost always fade or silence.

The same forecast also removes the wait at the track change itself. Music reports
the new track's rate within ~20 ms of the change when it had pre-buffered it; if
that report matches the forecast, two independent sources agree and the device is
switched at once instead of after the 2 s settling gate
(`RateSource.appleMusicConfirmedForecast`). That covers the "next" button, and any
boundary the timer could not anticipate.

**Turn off Music's Song Transitions (AutoMix / crossfade) for this to work as
intended.** With transitions on, Music moves to the next track a variable 5-30 s
before the listed end and plays both songs at once, so the end-of-track timer
never gets to fire and there is no silence for the dropout to land in; only the
instant switch at the change applies.

A seek makes Music re-create the playing track's own decoder, which would
otherwise overwrite the forecast with the playing track's rate. Seeks are
detected from the jump in reported position, and a same-rate decoder line that
coincides with one leaves the existing forecast alone. The log store query that
produces the forecast takes ~0.7 s and runs on its own queue, so it can never
delay a switch.

Status (September 2026): the end-of-track timer and the instant switch have both
been observed on real playback with Song Transitions off. The timer switched with
0.3 s of the song left and the next song started clean, with no switch inside it.
Keeping the forecast across a seek, and the separate query queue, are covered by
unit tests and a clean build but had not yet been watched working when pushed.

Only natural track endings are covered by the timer. A manual skip cannot be anticipated and
still switches a second or two in, as does a wrong forecast (e.g. the queue was
edited after Music pre-buffered). See `PreBoundarySwitchPolicy` in
`Quality/RateSwitchingPolicy.swift` and the "switch just before the track ends"
section of `Quality/OutputDevices.swift`.

### 3. Sparkle auto-update is disabled

`SUFeedURL` is removed and the updater is not started. Upstream's feed would
replace a build of this fork with upstream's release, silently dropping changes 1 and 2.
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
