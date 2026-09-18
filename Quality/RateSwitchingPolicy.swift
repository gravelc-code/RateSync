//
//  RateSwitchingPolicy.swift
//  RateSync
//

import CoreAudioTypes
import Foundation

/// The source of a candidate format determines how much evidence is needed
/// before changing the output device.
enum RateSource {
    case mediaRemoteProbe
    case appleMusicPriority
    /// Fork change: Music's own answer for the track that is playing right now.
    case appleMusicCurrentTrack
    /// Fork change: Music's answer for the playing track AND the format Music
    /// pre-buffered for it beforehand agree. Two independent sources, so no
    /// settling time is needed: switch at the track change itself.
    case appleMusicConfirmedForecast
    case appleMusicFormatLog
    case decoderLog
    case audioQueueLog
    case staleAudioQueueLog
    case preset
}

struct RateGatePolicy {
    let boundary: TimeInterval
    let stability: TimeInterval
    let lockedOverride: TimeInterval

    static let standard = RateGatePolicy(boundary: 3.5, stability: 2.0, lockedOverride: 12.0)
    static let appleMusicFormat = RateGatePolicy(boundary: 1.0, stability: 0.6, lockedOverride: 2.0)
    static let audioQueue = RateGatePolicy(boundary: 0, stability: 0.6, lockedOverride: 0.6)
    /// Fork change: not exposed to the decoder pre-buffer race, so it needs
    /// less settling time than log-derived rates; hard to override once applied.
    static let appleMusicCurrentTrack = RateGatePolicy(boundary: 1.0, stability: 1.0, lockedOverride: 12.0)
    /// Fork change: see RateSource.appleMusicConfirmedForecast.
    static let appleMusicConfirmedForecast = RateGatePolicy(boundary: 0, stability: 0, lockedOverride: 12.0)
}

enum RateSwitchingPolicy {
    static let maxPlausibleSampleRate: Double = 768_000
    static let maxPlausibleBitDepth: Int = 64

    static func gatePolicy(for source: RateSource) -> RateGatePolicy {
        switch source {
        case .audioQueueLog:
            return .audioQueue
        case .appleMusicFormatLog:
            return .appleMusicFormat
        case .appleMusicCurrentTrack:
            return .appleMusicCurrentTrack
        case .appleMusicConfirmedForecast:
            return .appleMusicConfirmedForecast
        case .staleAudioQueueLog, .mediaRemoteProbe, .appleMusicPriority, .decoderLog, .preset:
            return .standard
        }
    }

    static func bitDepth(reportedByMediaRemote: Int?, fallback: Int?) -> Int {
        reportedByMediaRemote ?? fallback ?? 24
    }

    static func shouldAcceptUnverifiedMediaRemoteFormat(expectedPID: pid_t?) -> Bool {
        expectedPID == nil
    }
}

enum PlayerTakeoverPolicy {
    static let defaultActivityWindow: TimeInterval = 15

    enum ActivePlayerRelation {
        case candidate
        case current
        case unknown
    }

    static func priorityIndex(
        for bundleIdentifier: String?,
        priority: [String]
    ) -> Int {
        guard let bundleIdentifier,
              let index = priority.firstIndex(of: bundleIdentifier) else {
            return priority.count
        }
        return index
    }

    /// Determines whether a newly observed source may replace the current
    /// source when the user selected automatic monitoring. A higher-priority
    /// source may take over immediately; a lower-priority source must wait
    /// until the current source has gone quiet long enough.
    static func shouldAccept(
        candidateBundleIdentifier: String?,
        currentBundleIdentifier: String?,
        currentLastSeenAt: Date?,
        now: Date,
        priority: [String],
        activityWindow: TimeInterval = defaultActivityWindow
    ) -> Bool {
        guard candidateBundleIdentifier != currentBundleIdentifier else { return true }
        guard currentBundleIdentifier != nil else { return true }

        let candidateIndex = priorityIndex(for: candidateBundleIdentifier, priority: priority)
        let currentIndex = priorityIndex(for: currentBundleIdentifier, priority: priority)
        if candidateIndex < currentIndex {
            return true
        }

        guard let currentLastSeenAt else { return true }
        return now.timeIntervalSince(currentLastSeenAt) > activityWindow
    }

    static func shouldAcceptAfterActivePlayerCheck(
        activePlayerRelation: ActivePlayerRelation,
        candidateBundleIdentifier: String?,
        currentBundleIdentifier: String?,
        currentLastSeenAt: Date?,
        now: Date,
        priority: [String],
        activityWindow: TimeInterval = defaultActivityWindow
    ) -> Bool {
        switch activePlayerRelation {
        case .candidate:
            return shouldAccept(
                candidateBundleIdentifier: candidateBundleIdentifier,
                currentBundleIdentifier: currentBundleIdentifier,
                currentLastSeenAt: currentLastSeenAt,
                now: now,
                priority: priority,
                activityWindow: activityWindow
            )
        case .current:
            return false
        case .unknown:
            return shouldAccept(
                candidateBundleIdentifier: candidateBundleIdentifier,
                currentBundleIdentifier: currentBundleIdentifier,
                currentLastSeenAt: currentLastSeenAt,
                now: now,
                priority: priority,
                activityWindow: activityWindow
            )
        }
    }
}

enum MenuSelectionState {
    static func effectiveSelectedIdentifier(
        selectedIdentifier: String?,
        temporaryLockIdentifier: String?
    ) -> String? {
        temporaryLockIdentifier ?? selectedIdentifier
    }

    static func isSelected(
        selectedIdentifier: String?,
        optionIdentifier: String?
    ) -> Bool {
        selectedIdentifier == optionIdentifier
    }
}

enum MonitoredSourceDecision: Equatable {
    case deliver
    case ignore

    static func decide(
        monitoredBundleIdentifier: String?,
        incomingBundleIdentifier: String?
    ) -> Self {
        guard let monitoredBundleIdentifier else { return .deliver }
        return incomingBundleIdentifier == monitoredBundleIdentifier ? .deliver : .ignore
    }
}

enum SourceIdentityPolicy {
    static func effectiveBundleIdentifier(
        reportedBundleIdentifier: String?,
        resolvedBundleIdentifier: String?,
        preferredBundleIdentifier: String?
    ) -> String? {
        if let preferredBundleIdentifier,
           reportedBundleIdentifier != preferredBundleIdentifier,
           resolvedBundleIdentifier == preferredBundleIdentifier {
            return resolvedBundleIdentifier
        }
        return reportedBundleIdentifier ?? resolvedBundleIdentifier
    }
}

enum MenuLabelPolicy {
    static func playerPriorityTitle(index: Int, localizedName: String) -> String {
        "\(index). \(localizedName)"
    }
}

enum AppleMusicPriorityPolicy {
    static func shouldPrioritize(
        monitoredBundleIdentifier: String?,
        sourceBundleIdentifier: String?,
        priority: [String] = PlayerProfile.defaultPriorityBundleIdentifiers,
        temporarySourceLockBundleIdentifier: String? = nil
    ) -> Bool {
        monitoredBundleIdentifier == nil
            && temporarySourceLockBundleIdentifier == nil
            && sourceBundleIdentifier != PlayerProfile.appleMusic.bundleIdentifier
            && priority.first == PlayerProfile.appleMusic.bundleIdentifier
    }
}

/// Fork change: timing rules for switching the output device just BEFORE a
/// track ends, using the format of the next track that Music has already
/// pre-buffered. Consecutive tracks at different rates come from different
/// masters, so there is no gapless continuity to protect, and the last
/// fraction of a second of a song is almost always fade or silence - a far
/// better place for the unavoidable dropout than 1-2 s into the next song.
/// Stateless so it can be tested apart from CoreAudio and AppleScript.
enum PreBoundarySwitchPolicy {
    /// How long before the end of the track the device is switched.
    static let lead: TimeInterval = 0.6
    /// Only arm once the end is this close; position is re-read when firing.
    static let armWindow: TimeInterval = 6.0
    /// Firing this close to the intended moment counts as on time.
    static let fireTolerance: TimeInterval = 0.35
    /// Below this the boundary is effectively here; leave it to the normal path.
    static let minimumUsefulRemaining: TimeInterval = 0.15
    /// After a pre-switch, keep the new rate this long while waiting for the
    /// track change, instead of switching straight back to the old track's rate.
    static let holdDuration: TimeInterval = 6.0

    enum ArmDecision: Equatable {
        case notYet
        case arm(after: TimeInterval)
        case tooLate
    }

    enum FireDecision: Equatable {
        case switchNow
        case rearm(after: TimeInterval)
        case abort
    }

    /// A prediction only matters when the next track's rate differs from the
    /// playing track's. An equal rate is either a same-rate next track or the
    /// playing track's own decoder - nothing to do in both cases.
    static func isUsefulPrediction(predictedRate: Double, currentTrackRate: Double) -> Bool {
        predictedRate > 0 && currentTrackRate > 0 && predictedRate != currentTrackRate
    }

    /// Seconds until the playing track ends, given a position reading that is
    /// `readingAge` seconds old. Nil when paused or when Music gave no position.
    static func remaining(position: Double?, duration: Double?, isPlaying: Bool, readingAge: TimeInterval) -> TimeInterval? {
        guard isPlaying, let position, let duration, duration > 0 else { return nil }
        return duration - position - readingAge
    }

    /// True when the format pre-buffered during the previous track matches
    /// what Music now reports for the playing track.
    static func forecastConfirms(forecastRate: Double?, reportedRate: Double) -> Bool {
        guard let forecastRate, forecastRate > 0, reportedRate > 0 else { return false }
        return forecastRate == reportedRate
    }

    static func armDecision(remaining: TimeInterval) -> ArmDecision {
        guard remaining.isFinite, remaining >= minimumUsefulRemaining else { return .tooLate }
        guard remaining <= armWindow else { return .notYet }
        return .arm(after: max(0, remaining - lead))
    }

    /// Re-evaluated with a fresh position when the timer fires, so a seek or
    /// pause since arming can never cause a switch in the middle of a song.
    static func fireDecision(remaining: TimeInterval) -> FireDecision {
        guard remaining.isFinite, remaining >= minimumUsefulRemaining else { return .abort }
        if remaining <= lead + fireTolerance { return .switchNow }
        if remaining <= armWindow { return .rearm(after: remaining - lead) }
        return .abort
    }
}

enum AppleMusicFormatPolicy {
    enum Resolution: Equatable {
        case logEvidence
        case cachedFallback
        case requestAppleScript
        case noFormat
    }

    static func shouldUseAppleScriptFallback(
        hasKnownFormat: Bool,
        hasAttemptedFallback: Bool = false
    ) -> Bool {
        !hasKnownFormat && !hasAttemptedFallback
    }

    static func resolution(
        hasLogEvidence: Bool,
        hasLogStats: Bool,
        hasCachedFallback: Bool,
        hasAttemptedFallback: Bool,
        isPlaying: Bool
    ) -> Resolution {
        if hasLogEvidence {
            return .logEvidence
        }
        if hasCachedFallback {
            return .cachedFallback
        }
        if !hasLogStats, isPlaying, !hasAttemptedFallback {
            return .requestAppleScript
        }
        return .noFormat
    }

    static func shouldReplaceCachedFormat(
        currentIsDolbyAtmos: Bool,
        incomingIsDolbyAtmos: Bool
    ) -> Bool {
        !currentIsDolbyAtmos || incomingIsDolbyAtmos
    }
}

/// Selects the device format closest to the format reported by the player.
/// This is deliberately stateless so the matching policy can be tested apart
/// from CoreAudio and the event-driven switching pipeline.
enum AudioFormatSelector {
    static func nearestFormat(
        sampleRate: Float64,
        bitDepth: Int32,
        supportedSampleRates: [Float64],
        formats: [AudioStreamBasicDescription],
        preferSampleRateMultiples: Bool
    ) -> AudioStreamBasicDescription? {
        guard let closestRate = supportedSampleRates.min(by: {
            abs($0 - sampleRate) < abs($1 - sampleRate)
        }) else {
            return nil
        }

        var targetRate = closestRate
        if preferSampleRateMultiples,
           closestRate != sampleRate,
           supportedSampleRates.contains(sampleRate / 2) {
            targetRate = sampleRate / 2
        }

        let formatsAtTargetRate = formats.filter { $0.mSampleRate == targetRate }
        let closestBitDepth = formatsAtTargetRate.min(by: {
            let lhsDistance = abs(Int32($0.mBitsPerChannel) - bitDepth)
            let rhsDistance = abs(Int32($1.mBitsPerChannel) - bitDepth)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return $0.mBitsPerChannel < $1.mBitsPerChannel
        })?.mBitsPerChannel

        guard let closestBitDepth else { return nil }
        return formatsAtTargetRate.first {
            $0.mSampleRate == targetRate && $0.mBitsPerChannel == closestBitDepth
        }
    }
}
