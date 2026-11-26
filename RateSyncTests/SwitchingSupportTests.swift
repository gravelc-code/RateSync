import Foundation
import XCTest

final class SwitchingSupportTests: XCTestCase {
    func testResolvesAudioQueueProfileForKnownBundleIdentifier() {
        // Given
        let netEaseMusicBundleIdentifier = "com.netease.163music"

        // When
        let profile = PlayerProfile.profile(for: netEaseMusicBundleIdentifier)

        // Then
        XCTAssertEqual(profile?.processName, "NeteaseMusic")
        XCTAssertEqual(profile?.formatDetection, .audioQueueLogs)
    }

    func testFreshAudioQueueCandidateDoesNotWaitTwelveSecondsAfterExistingResult() {
        let policy = RateSwitchingPolicy.gatePolicy(for: .audioQueueLog)

        XCTAssertEqual(
            policy.lockedOverride,
            policy.stability,
            accuracy: 0.001,
            "fresh AudioQueue evidence should use the short stability window even after a prior result"
        )
    }

    func testAppleMusicCurrentTrackRateSettlesFasterThanLogsButResistsOverride() {
        let policy = RateSwitchingPolicy.gatePolicy(for: .appleMusicCurrentTrack)
        let logPolicy = RateSwitchingPolicy.gatePolicy(for: .decoderLog)

        XCTAssertLessThan(
            policy.stability,
            logPolicy.stability,
            "Music's own answer for the playing track is not exposed to the next-track decoder pre-buffer race"
        )
        XCTAssertGreaterThan(policy.stability, 0, "a single read must never be enough to switch the device")
        XCTAssertEqual(
            policy.lockedOverride,
            logPolicy.lockedOverride,
            accuracy: 0.001,
            "once applied for a track it should be as hard to override as any other source"
        )
    }

    func testPreBoundarySwitchIgnoresSameRateForecast() {
        XCTAssertFalse(
            PreBoundarySwitchPolicy.isUsefulPrediction(predictedRate: 96_000, currentTrackRate: 96_000),
            "an equal rate is a same-rate next track or the playing track's own decoder"
        )
        XCTAssertTrue(PreBoundarySwitchPolicy.isUsefulPrediction(predictedRate: 44_100, currentTrackRate: 96_000))
        XCTAssertFalse(PreBoundarySwitchPolicy.isUsefulPrediction(predictedRate: 0, currentTrackRate: 96_000))
    }

    func testPreBoundarySwitchArmsOnlyNearTheEndOfTheTrack() {
        XCTAssertEqual(PreBoundarySwitchPolicy.armDecision(remaining: 120), .notYet)
        XCTAssertEqual(
            PreBoundarySwitchPolicy.armDecision(remaining: 4.0),
            .arm(after: 4.0 - PreBoundarySwitchPolicy.lead)
        )
        XCTAssertEqual(
            PreBoundarySwitchPolicy.armDecision(remaining: 0.3),
            .arm(after: 0),
            "inside the lead but before the boundary: switch immediately rather than 1-2 s into the next song"
        )
        XCTAssertEqual(PreBoundarySwitchPolicy.armDecision(remaining: 0.05), .tooLate)
        XCTAssertEqual(PreBoundarySwitchPolicy.armDecision(remaining: -3), .tooLate)
    }

    func testPreBoundarySwitchNeverFiresInTheMiddleOfASong() {
        XCTAssertEqual(PreBoundarySwitchPolicy.fireDecision(remaining: PreBoundarySwitchPolicy.lead), .switchNow)
        XCTAssertEqual(
            PreBoundarySwitchPolicy.fireDecision(remaining: 3.0),
            .rearm(after: 3.0 - PreBoundarySwitchPolicy.lead),
            "a small seek back since arming re-schedules instead of switching early"
        )
        XCTAssertEqual(
            PreBoundarySwitchPolicy.fireDecision(remaining: 150),
            .abort,
            "a seek to the middle of the song since arming must not switch the device"
        )
        XCTAssertEqual(PreBoundarySwitchPolicy.fireDecision(remaining: -0.2), .abort)
        XCTAssertEqual(PreBoundarySwitchPolicy.fireDecision(remaining: .nan), .abort)
    }

    func testRemainingTimeAccountsForAgeOfTheReading() {
        XCTAssertEqual(
            PreBoundarySwitchPolicy.remaining(position: 200, duration: 210, isPlaying: true, readingAge: 2) ?? -1,
            8,
            accuracy: 0.001
        )
        XCTAssertNil(PreBoundarySwitchPolicy.remaining(position: 200, duration: 210, isPlaying: false, readingAge: 0))
        XCTAssertNil(PreBoundarySwitchPolicy.remaining(position: nil, duration: 210, isPlaying: true, readingAge: 0))
        XCTAssertNil(PreBoundarySwitchPolicy.remaining(position: 10, duration: 0, isPlaying: true, readingAge: 0))
    }

    func testConfirmedForecastSwitchesWithoutSettlingTime() {
        XCTAssertTrue(PreBoundarySwitchPolicy.forecastConfirms(forecastRate: 48_000, reportedRate: 48_000))
        XCTAssertFalse(PreBoundarySwitchPolicy.forecastConfirms(forecastRate: 44_100, reportedRate: 48_000))
        XCTAssertFalse(PreBoundarySwitchPolicy.forecastConfirms(forecastRate: nil, reportedRate: 48_000))

        let policy = RateSwitchingPolicy.gatePolicy(for: .appleMusicConfirmedForecast)
        XCTAssertEqual(policy.boundary, 0, accuracy: 0.001)
        XCTAssertEqual(policy.stability, 0, accuracy: 0.001, "two agreeing sources: switch at the track change itself")
        XCTAssertGreaterThan(
            RateSwitchingPolicy.gatePolicy(for: .appleMusicCurrentTrack).stability,
            0,
            "an unconfirmed report must still settle before the device is switched"
        )
    }

    func testSeekDoesNotDiscardAValidNextTrackForecast() {
        // Held forecast 44.1 kHz, playing 48 kHz, new line is the playing track's own rate.
        XCTAssertEqual(
            PreBoundarySwitchPolicy.forecastUpdate(heldRate: 44_100, newRate: 48_000, playingRate: 48_000, lineAge: 0.3, secondsBetweenLineAndSeek: nil),
            .decideLater,
            "the update that reveals a seek arrives after the decoder line"
        )
        XCTAssertEqual(
            PreBoundarySwitchPolicy.forecastUpdate(heldRate: 44_100, newRate: 48_000, playingRate: 48_000, lineAge: 1.5, secondsBetweenLineAndSeek: 0.18),
            .keepExisting
        )
        XCTAssertEqual(
            PreBoundarySwitchPolicy.forecastUpdate(heldRate: 44_100, newRate: 48_000, playingRate: 48_000, lineAge: 1.5, secondsBetweenLineAndSeek: nil),
            .replace,
            "no seek: the queue changed and the next track is now the same rate"
        )
        XCTAssertEqual(
            PreBoundarySwitchPolicy.forecastUpdate(heldRate: 44_100, newRate: 96_000, playingRate: 48_000, lineAge: 0.1, secondsBetweenLineAndSeek: 0.1),
            .replace,
            "a line at a different rate cannot be the playing track's own decoder"
        )
        XCTAssertEqual(
            PreBoundarySwitchPolicy.forecastUpdate(heldRate: nil, newRate: 48_000, playingRate: 48_000, lineAge: 0.1, secondsBetweenLineAndSeek: 0.1),
            .replace
        )
    }

    func testSeekDetectionIgnoresNormalPlaybackAndPauses() {
        XCTAssertFalse(PreBoundarySwitchPolicy.isSeek(previousElapsed: 10, previousTimestamp: 100, previousRate: 1, elapsed: 13.1, timestamp: 103))
        XCTAssertTrue(PreBoundarySwitchPolicy.isSeek(previousElapsed: 10, previousTimestamp: 100, previousRate: 1, elapsed: 290, timestamp: 103))
        XCTAssertTrue(PreBoundarySwitchPolicy.isSeek(previousElapsed: 200, previousTimestamp: 100, previousRate: 1, elapsed: 5, timestamp: 101))
        XCTAssertFalse(
            PreBoundarySwitchPolicy.isSeek(previousElapsed: 50, previousTimestamp: 100, previousRate: 0, elapsed: 50, timestamp: 160),
            "resuming after a long pause is not a seek"
        )
    }

    func testStaleAudioQueueCandidateKeepsConservativePersistenceWindow() {
        let policy = RateSwitchingPolicy.gatePolicy(for: .staleAudioQueueLog)

        XCTAssertEqual(
            policy.lockedOverride,
            12.0,
            accuracy: 0.001,
            "stale AudioQueue evidence must not bypass the long persistence guard"
        )
    }

    func testMediaRemoteOnlyAcceptsUnverifiedFormatWithoutExpectedPID() {
        XCTAssertTrue(
            RateSwitchingPolicy.shouldAcceptUnverifiedMediaRemoteFormat(expectedPID: nil)
        )
        XCTAssertFalse(
            RateSwitchingPolicy.shouldAcceptUnverifiedMediaRemoteFormat(expectedPID: 42)
        )
    }

    func testAppleMusicParserPrefersDolbyAtmosFormatOverNearbyLossless44_1Log() {
        let entries = [
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 106),
                message: "ACAppleLosslessDecoder.cpp:680 Input format: 2 ch, 44100 Hz, alac (0x00000001) from 16-bit source"
            ),
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 107),
                message: "play> cm>> mediaFormatinfo '<private>' , asbdFormatID = qlac, lossless, asbdSampleRate = 44.1 kHz, is not rendering spatial audio"
            ),
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 105),
                message: "play> cm>> mediaFormatinfo '<private>' , asbdFormatID = qaac, sdFormatID = aac, stereo (lossy), asbdSampleRate = 48.0 kHz, is binaural, is rendering spatial audio, 16 original channels, original is Atmos"
            )
        ]

        let stat = AppleMusicFormatParser.parse(entries).first

        XCTAssertEqual(stat?.sampleRate, 48_000)
        XCTAssertTrue(stat?.isDolbyAtmos == true)
    }

    func testAppleMusicParserRecognizesQc3DolbyAtmosMarker() {
        let entries = [
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 305),
                message: "play> cm>> mediaFormatinfo '<private>' , asbdFormatID = qc+3, sdFormatID = ec+3, Dolby Atmos, asbdNumChannels = 16, asbdSampleRate = 48.0 kHz, is not rendering spatial audio, is Atmos"
            )
        ]

        let stat = AppleMusicFormatParser.parse(entries).first

        XCTAssertEqual(stat?.sampleRate, 48_000)
        XCTAssertTrue(stat?.isDolbyAtmos == true)
    }

    func testAppleMusicParserUsesHighLevelLosslessFormatBeforeDecoderLog() {
        let entries = [
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 205),
                message: "ACAppleLosslessDecoder.cpp:680 Input format: 2 ch, 44100 Hz, alac (0x00000001) from 16-bit source"
            ),
            AppleMusicLogEntry(
                date: Date(timeIntervalSince1970: 204),
                message: "play> cm>> mediaFormatinfo '<private>' , audioCapabilities: 0x0 -> 0x4, asbdFormatID = qlac, lossless, asbdNumChannels = 2, asbdSampleRate = 48.0 kHz, is not rendering spatial audio"
            )
        ]

        let stat = AppleMusicFormatParser.parse(entries).first

        XCTAssertEqual(stat?.sampleRate, 48_000)
        XCTAssertFalse(stat?.isDolbyAtmos == true)
    }

    func testAppleMusicHighLevelFormatUsesShortEvidenceGate() {
        let policy = RateSwitchingPolicy.gatePolicy(for: .appleMusicFormatLog)

        XCTAssertEqual(policy.boundary, 1.0, accuracy: 0.001)
        XCTAssertEqual(policy.stability, 0.6, accuracy: 0.001)
        XCTAssertEqual(policy.lockedOverride, 2.0, accuracy: 0.001)
    }

    func testAppleMusicEvidenceWindowRetainsDelayedDolbyFormat() {
        let atmosphericDate = Date(timeIntervalSince1970: 100)
        let losslessDate = Date(timeIntervalSince1970: 107)
        let queryDate = Date(timeIntervalSince1970: 110)
        let entries = [
            AppleMusicLogEntry(
                date: atmosphericDate,
                message: "asbdFormatID = qaac, asbdSampleRate = 48.0 kHz, original is Atmos"
            ),
            AppleMusicLogEntry(
                date: losslessDate,
                message: "asbdFormatID = qlac, lossless, asbdSampleRate = 44.1 kHz, is not rendering spatial audio"
            )
        ].filter { $0.date >= queryDate.addingTimeInterval(-AppleMusicFormatParser.logWindowSeconds) }

        let stat = AppleMusicFormatParser.parse(entries).first

        XCTAssertEqual(stat?.sampleRate, 48_000)
        XCTAssertTrue(stat?.isDolbyAtmos == true)
    }

    func testAppleMusicKnownFormatBlocksScriptFallbackAndKeepsAtmosEvidence() {
        XCTAssertFalse(AppleMusicFormatPolicy.shouldUseAppleScriptFallback(hasKnownFormat: true))
        XCTAssertTrue(AppleMusicFormatPolicy.shouldUseAppleScriptFallback(hasKnownFormat: false))
        XCTAssertFalse(
            AppleMusicFormatPolicy.shouldUseAppleScriptFallback(
                hasKnownFormat: false,
                hasAttemptedFallback: true
            )
        )
        XCTAssertFalse(
            AppleMusicFormatPolicy.shouldReplaceCachedFormat(
                currentIsDolbyAtmos: true,
                incomingIsDolbyAtmos: false
            )
        )
        XCTAssertTrue(
            AppleMusicFormatPolicy.shouldReplaceCachedFormat(
                currentIsDolbyAtmos: false,
                incomingIsDolbyAtmos: true
            )
        )
    }

    func testResolvesPresetRateForSpotify() {
        // Given
        let spotifyBundleIdentifier = "com.spotify.client"

        // When
        let profile = PlayerProfile.profile(for: spotifyBundleIdentifier)

        // Then
        XCTAssertEqual(profile?.fallbackSampleRate, 44_100)
    }

    func testPlayerPriorityNormalizationKeepsCustomOrderAndAddsMissingPlayers() {
        let priority = PlayerProfile.normalizedPriority([
            PlayerProfile.qqMusic.bundleIdentifier,
            PlayerProfile.qqMusic.bundleIdentifier,
            PlayerProfile.appleMusic.bundleIdentifier,
            "com.example.unknown-player"
        ])

        XCTAssertEqual(
            priority,
            [
                PlayerProfile.qqMusic.bundleIdentifier,
                PlayerProfile.appleMusic.bundleIdentifier,
                PlayerProfile.spotify.bundleIdentifier,
                PlayerProfile.neteaseMusic.bundleIdentifier,
                PlayerProfile.tidal.bundleIdentifier
            ]
        )
    }

    func testHigherPriorityPlayerCanTakeOverImmediately() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            PlayerTakeoverPolicy.shouldAccept(
                candidateBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                currentBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier,
                currentLastSeenAt: now,
                now: now.addingTimeInterval(1),
                priority: PlayerProfile.defaultPriorityBundleIdentifiers
            )
        )
    }

    func testLowerPriorityPlayerWaitsWhileCurrentSourceIsFresh() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(
            PlayerTakeoverPolicy.shouldAccept(
                candidateBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier,
                currentBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                currentLastSeenAt: now,
                now: now.addingTimeInterval(1),
                priority: PlayerProfile.defaultPriorityBundleIdentifiers
            )
        )
    }

    func testLowerPriorityPlayerCanTakeOverAfterCurrentSourceGoesQuiet() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            PlayerTakeoverPolicy.shouldAccept(
                candidateBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier,
                currentBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                currentLastSeenAt: now,
                now: now.addingTimeInterval(PlayerTakeoverPolicy.defaultActivityWindow + 1),
                priority: PlayerProfile.defaultPriorityBundleIdentifiers
            )
        )
    }

    func testActiveLowerPriorityPlayerStillWaitsWhileCurrentSourceIsFresh() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(
            PlayerTakeoverPolicy.shouldAcceptAfterActivePlayerCheck(
                activePlayerRelation: .candidate,
                candidateBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier,
                currentBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                currentLastSeenAt: now,
                now: now.addingTimeInterval(1),
                priority: PlayerProfile.defaultPriorityBundleIdentifiers
            ),
            "an active lower-priority candidate must not bypass the freshness window"
        )
    }

    func testMismatchedMonitoredSourceIsIgnored() {
        XCTAssertEqual(
            MonitoredSourceDecision.decide(
                monitoredBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                incomingBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier
            ),
            .ignore,
            "an event from outside the monitored source must not clear the selected source"
        )
    }

    func testStaleReportedSourceUsesResolvedPreferredSource() {
        XCTAssertEqual(
            SourceIdentityPolicy.effectiveBundleIdentifier(
                reportedBundleIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier,
                resolvedBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                preferredBundleIdentifier: PlayerProfile.appleMusic.bundleIdentifier
            ),
            PlayerProfile.appleMusic.bundleIdentifier,
            "a stale MediaRemote source id must not hide the monitored process identity"
        )
    }

    func testTemporaryLockBecomesTheEffectiveMonitorSelection() {
        XCTAssertEqual(
            MenuSelectionState.effectiveSelectedIdentifier(
                selectedIdentifier: PlayerProfile.appleMusic.bundleIdentifier,
                temporaryLockIdentifier: PlayerProfile.neteaseMusic.bundleIdentifier
            ),
            PlayerProfile.neteaseMusic.bundleIdentifier,
            "the temporary lock must be the source shown as effective in the menu"
        )
    }

    func testResolvesBundleIdentifierForKnownProcessName() {
        // Given
        let processName = "Music"

        // When
        let bundleIdentifier = PlayerProfile.bundleIdentifier(forProcessName: processName)

        // Then
        XCTAssertEqual(bundleIdentifier, "com.apple.Music")
    }

    func testMonitoringSourcesExposeTheirLocalizationKeys() {
        XCTAssertEqual(
            PlayerProfile.monitoringSources.map(\.localizationKey),
            ["Apple Music", "Spotify", "NetEase Music", "QQ Music", "TIDAL"]
        )
    }

    func testMenuSelectionStateMarksMatchingIdentifierAsSelected() {
        XCTAssertTrue(
            MenuSelectionState.isSelected(
                selectedIdentifier: "device-a",
                optionIdentifier: "device-a"
            )
        )
        XCTAssertFalse(
            MenuSelectionState.isSelected(
                selectedIdentifier: "device-a",
                optionIdentifier: "device-b"
            )
        )
    }

    func testMenuSelectionStateMarksDefaultOptionOnlyWhenSelectionIsNil() {
        XCTAssertTrue(
            MenuSelectionState.isSelected(
                selectedIdentifier: nil,
                optionIdentifier: nil
            )
        )
        XCTAssertFalse(
            MenuSelectionState.isSelected(
                selectedIdentifier: "device-a",
                optionIdentifier: nil
            )
        )
    }

    func testCompletesOneShotCallbackOnlyOnce() {
        // Given
        var values = [Int]()
        let completion = OneShotCompletion<Int> { values.append($0) }

        // When
        completion.complete(1)
        completion.complete(2)

        // Then
        XCTAssertEqual(values, [1])
    }

    func testCompletesOneShotCallbackOnceWhenCallsRace() {
        // Given
        let callbackExpectation = expectation(description: "callback")
        let completion = OneShotCompletion<Int> { _ in callbackExpectation.fulfill() }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "OneShotCompletionTests", attributes: .concurrent)

        // When
        for value in 0..<100 {
            group.enter()
            queue.async {
                completion.complete(value)
                group.leave()
            }
        }

        // Then
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        wait(for: [callbackExpectation], timeout: 1)
    }

    func testWidgetKindKeepsExistingInstalledWidgetsCompatible() {
        XCTAssertEqual(RateSyncWidgetConfiguration.widgetKind, "RateSyncAudioFormatWidget")
    }

    func testWidgetRefreshRetriesAfterAppUpdateToOutliveStaleExtensionHost() {
        XCTAssertEqual(
            RateSyncWidgetConfiguration.launchRefreshDelays,
            [0, 5, 15]
        )
    }

    func testWidgetTimelineHasFallbackRefreshForExternalFormatChanges() {
        let start = Date(timeIntervalSince1970: 1_000)

        let refresh = RateSyncWidgetConfiguration.nextRefreshDate(after: start)

        XCTAssertEqual(
            refresh.timeIntervalSince(start),
            RateSyncWidgetConfiguration.fallbackRefreshInterval,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(RateSyncWidgetConfiguration.fallbackRefreshInterval, 0)
    }

    func testWidgetNowPlayingFallbackTextIsReadable() {
        let track = SharedNowPlayingTrack(
            title: "  ",
            artist: nil,
            artworkDataBase64: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(track.titleText, "Not Playing")
        XCTAssertEqual(track.artistText, "No Artist")
    }

    func testWidgetStateFallbackURLLivesInWidgetContainer() {
        let path = RateSyncWidgetConfiguration.localWidgetStateURL.path

        XCTAssertTrue(
            path.hasSuffix(
                "/Library/Containers/com.biking.RateSync.Widget/Data/Library/Application Support/RateSync/ratesync-widget-state.plist"
            )
        )
    }

    func testWidgetStateUsesOnlyStandaloneContainerFileBridge() {
        let paths = RateSyncWidgetConfiguration.stateStorageURLs.map(\.path)

        XCTAssertEqual(paths, [RateSyncWidgetConfiguration.localWidgetStateURL.path])
        XCTAssertFalse(paths.contains { $0.contains("/Library/Group Containers/") })
    }

    func testReplayWithSameMetadataButNewNowPlayingTimestampIsNotSuppressed() {
        let first = TrackEventIdentity(
            title: "Same Song",
            artist: "Same Artist",
            album: "Same Album",
            artworkDataBase64: nil,
            bundleIdentifier: "com.example.player",
            processID: 42,
            timestampEpochMicros: 1_000_000
        )
        let replay = TrackEventIdentity(
            title: "Same Song",
            artist: "Same Artist",
            album: "Same Album",
            artworkDataBase64: nil,
            bundleIdentifier: "com.example.player",
            processID: 42,
            timestampEpochMicros: 2_000_000
        )

        XCTAssertFalse(
            TrackEventIdentity.shouldSuppressDuplicate(
                previous: first,
                current: replay,
                lastDeliveredAt: Date(timeIntervalSince1970: 100),
                now: Date(timeIntervalSince1970: 100.1)
            )
        )
    }

    func testRepeatedCallbackWithSameNowPlayingTimestampIsSuppressed() {
        let first = TrackEventIdentity(
            title: "Same Song",
            artist: "Same Artist",
            album: "Same Album",
            artworkDataBase64: nil,
            bundleIdentifier: "com.example.player",
            processID: 42,
            timestampEpochMicros: 1_000_000
        )

        XCTAssertTrue(
            TrackEventIdentity.shouldSuppressDuplicate(
                previous: first,
                current: first,
                lastDeliveredAt: Date(timeIntervalSince1970: 100),
                now: Date(timeIntervalSince1970: 100.1)
            )
        )
    }

    func testArtworkSanitizerRejectsOversizedBase64Payload() {
        let oversizedArtwork = Data(
            repeating: 0,
            count: RateSyncWidgetConfiguration.maxArtworkDataBytes + 1
        ).base64EncodedString()

        XCTAssertNil(
            RateSyncWidgetConfiguration.sanitizedArtworkDataBase64(oversizedArtwork)
        )
    }

    func testArtworkSanitizerKeepsValidBase64Payload() {
        let artwork = Data([0x01, 0x02, 0x03]).base64EncodedString()

        XCTAssertEqual(
            RateSyncWidgetConfiguration.sanitizedArtworkDataBase64(artwork),
            artwork
        )
    }

    func testAppleMusicFallbackKeepsPollingForLaterLogEvidence() {
        XCTAssertEqual(
            AppleMusicFormatPolicy.resolution(
                hasLogEvidence: false,
                hasLogStats: false,
                hasCachedFallback: true,
                hasAttemptedFallback: true,
                isPlaying: true
            ),
            .cachedFallback
        )
        XCTAssertEqual(
            AppleMusicFormatPolicy.resolution(
                hasLogEvidence: true,
                hasLogStats: true,
                hasCachedFallback: true,
                hasAttemptedFallback: true,
                isPlaying: true
            ),
            .logEvidence
        )
    }

    func testWidgetStateMergesLatestIndependentFormatAndTrackSnapshots() {
        let older = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 44_100,
            bitDepth: 16,
            formatUpdatedAt: Date(timeIntervalSince1970: 10),
            title: "Older title",
            artist: "Older artist",
            artworkDataBase64: nil,
            trackUpdatedAt: Date(timeIntervalSince1970: 20)
        )
        let newerFormat = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 48_000,
            bitDepth: 24,
            formatUpdatedAt: Date(timeIntervalSince1970: 30),
            title: nil,
            artist: nil,
            artworkDataBase64: nil,
            trackUpdatedAt: nil
        )

        let merged = RateSyncWidgetConfiguration.mergeStates([older, newerFormat])

        XCTAssertEqual(merged?.sampleRate, 48_000)
        XCTAssertEqual(merged?.bitDepth, 24)
        XCTAssertEqual(merged?.title, "Older title")
        XCTAssertEqual(merged?.artist, "Older artist")
        XCTAssertEqual(merged?.trackUpdatedAt, Date(timeIntervalSince1970: 20))
    }

    func testWidgetStateUsesFreshSharedDefaultsWhenStateFileIsStale() {
        let staleFileState = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 48_000,
            bitDepth: 32,
            formatUpdatedAt: Date(timeIntervalSince1970: 10),
            title: nil,
            artist: nil,
            artworkDataBase64: nil,
            trackUpdatedAt: nil
        )
        let freshSharedDefaultsState = RateSyncWidgetConfiguration.WidgetState(
            sampleRate: 44_100,
            bitDepth: 24,
            formatUpdatedAt: Date(timeIntervalSince1970: 30),
            title: "Current song",
            artist: "Current artist",
            artworkDataBase64: nil,
            trackUpdatedAt: Date(timeIntervalSince1970: 31)
        )

        let merged = RateSyncWidgetConfiguration.mergePersistedStates(
            fileStates: [staleFileState],
            sharedDefaultsState: freshSharedDefaultsState
        )

        XCTAssertEqual(merged?.sampleRate, 44_100)
        XCTAssertEqual(merged?.bitDepth, 24)
        XCTAssertEqual(merged?.title, "Current song")
        XCTAssertEqual(merged?.artist, "Current artist")
        XCTAssertEqual(merged?.trackUpdatedAt, Date(timeIntervalSince1970: 31))
    }

    func testWidgetPrefersLiveOutputFormatWhenPersistedStateIsStale() {
        let persisted = SharedAudioFormat(
            sampleRate: 44_100,
            bitDepth: 16,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let live = SharedAudioFormat(
            sampleRate: 48_000,
            bitDepth: 24,
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(
            RateSyncWidgetConfiguration.preferredAudioFormat(
                persisted: persisted,
                live: live
            ),
            live
        )
    }

    func testWidgetAudioFormatUsesPersistedStateWithoutLiveOutputProbe() {
        let persisted = SharedAudioFormat(
            sampleRate: 44_100,
            bitDepth: 32,
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(
            RateSyncWidgetConfiguration.widgetAudioFormat(persisted: persisted),
            persisted
        )
    }

    func testPlayerPriorityMenuTitleIncludesPlayerNameAfterOrderNumber() {
        XCTAssertEqual(
            MenuLabelPolicy.playerPriorityTitle(index: 1, localizedName: "Apple Music"),
            "1. Apple Music",
            "Player priority rows must show the player name instead of only the order number."
        )
    }

    // MARK: - Fork change: TIDAL

    func testTidalProfileReadsItsPlayerLog() {
        let profile = PlayerProfile.profile(for: "com.tidal.desktop")

        XCTAssertEqual(profile?.formatDetection, .tidalPlayerLog)
        XCTAssertTrue(PlayerProfile.monitoringSources.contains(.tidal))
        XCTAssertEqual(
            PlayerProfile.normalizedPriority([]).last,
            "com.tidal.desktop",
            "TIDAL is appended to the priority list without reordering existing players"
        )
    }

    func testTidalSinkLineParsesRateDepthAndTimestamp() throws {
        let line = "[2026-11-26 10:38:54.782] [tisoc] [debug] [pcm_sink_coreaudio.cpp:35] CoreaudioSink::open, rate: 96000, type: int24"

        let format = try XCTUnwrap(TidalPlayerLog.parseLine(line))

        XCTAssertEqual(format.sampleRate, 96_000)
        XCTAssertEqual(format.bitDepth, 24)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: format.date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 11)
        XCTAssertEqual(components.day, 26)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 38)
        XCTAssertEqual(components.second, 54)
        XCTAssertEqual(Double(components.nanosecond ?? 0) / 1e9, 0.782, accuracy: 0.002)
    }

    func testTidalParserTakesNewestSinkLineAndIgnoresOtherLines() {
        let log = """
        [2026-11-26 10:37:02.314] [tisoc] [debug] [pcm_sink_coreaudio.cpp:35] CoreaudioSink::open, rate: 176400, type: int24
        [2026-11-26 10:37:04.184] [tisoc] [debug] [factory.cpp:70] AudioDecoderFactory::create - got stream format flac
        [2026-11-26 10:37:04.459] [tisoc] [debug] [pcm_sink_coreaudio.cpp:35] CoreaudioSink::open, rate: 44100, type: int16
        [2026-11-26 10:39:05.704] [tisoc] [debug] [desktop_console.cpp:129] COMMAND: {"command":"media.preload"}
        [2026-11-26 10:39:05.780] [tisoc] [debug] [pcm_sink_coreaudio.cpp:35] CoreaudioSink::open, rate: 96000, type: int24
        [2026-11-26 10:39:05.919] [tisoc] [debug] [pcm_sink_coreaudio.cpp:207] CoreaudioSink::start
        """

        let formats = TidalPlayerLog.parse(log)

        XCTAssertEqual(formats.map(\.sampleRate), [176_400, 44_100, 96_000])
        XCTAssertEqual(formats.map(\.bitDepth), [24, 16, 24])
    }

    func testTidalParserRejectsMalformedSinkLines() {
        XCTAssertNil(TidalPlayerLog.parseLine("CoreaudioSink::open, rate: 96000, type: int24"))
        XCTAssertNil(TidalPlayerLog.parseLine("[2026-11-26 10:38:54.782] CoreaudioSink::open, rate: 0, type: int24"))
        XCTAssertNil(TidalPlayerLog.parseLine("[not a date] CoreaudioSink::open, rate: 96000, type: int24"))
        XCTAssertEqual(TidalPlayerLog.bitDepth(forSampleType: "float32"), 32)
        XCTAssertNil(TidalPlayerLog.bitDepth(forSampleType: "pcm"))
    }

    func testTidalNewestSinkFormatReadsTailOfFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidal-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        // Pad past the tail window so only the end of the file is read.
        var text = String(repeating: "[2026-11-26 09:00:00.000] [tisoc] [info] padding padding padding\n", count: 6_000)
        text += "[2026-11-26 10:00:00.000] [tisoc] [debug] [pcm_sink_coreaudio.cpp:35] CoreaudioSink::open, rate: 48000, type: int24\n"
        text += "[2026-11-26 10:05:00.000] [tisoc] [debug] [pcm_sink_coreaudio.cpp:35] CoreaudioSink::open, rate: 96000, type: int24\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(text.utf8.count, TidalPlayerLog.tailBytes)

        XCTAssertEqual(TidalPlayerLog.newestSinkFormat(at: url)?.sampleRate, 96_000)
        XCTAssertNil(TidalPlayerLog.newestSinkFormat(at: url.appendingPathExtension("missing")))
    }

    func testTidalSnapshotIsPlayingOnlyWhenNewestStateIsActive() {
        let sink = "[2026-11-26 11:02:21.700] [tisoc] [debug] [pcm_sink_coreaudio.cpp:35] CoreaudioSink::open, rate: 192000, type: int24"
        let active = #"[2026-11-26 11:02:21.961] [tisoc] [debug] [client.hpp:37] SIGNAL: {"signal": "media.state", "state": "active", "url": "https://example"}"#
        let paused = #"[2026-11-26 11:05:00.000] [tisoc] [debug] [client.hpp:37] SIGNAL: {"signal": "media.state", "state": "paused", "url": "https://example"}"#

        let playing = TidalPlayerLog.parseSnapshot([sink, active].joined(separator: "\n"))
        XCTAssertTrue(playing.isPlaying)
        XCTAssertEqual(playing.newestSink?.sampleRate, 192_000)

        let pausedLater = TidalPlayerLog.parseSnapshot([sink, active, paused].joined(separator: "\n"))
        XCTAssertFalse(
            pausedLater.isPlaying,
            "a paused TIDAL must never switch the device under another player"
        )
        XCTAssertEqual(pausedLater.newestSink?.sampleRate, 192_000)

        XCTAssertFalse(TidalPlayerLog.parseSnapshot(sink).isPlaying, "no state logged means not known to be playing")
        XCTAssertEqual(TidalPlayerLog.playbackState(inLine: paused), "paused")
        XCTAssertNil(TidalPlayerLog.playbackState(inLine: sink))
    }

    func testTidalLineFromBeforeTrackChangeIsHeldBackOnlyBriefly() {
        let change = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            TidalSwitchPolicy.lineMayBePreviousTrack(lineDate: change.addingTimeInterval(-180), trackChangeDate: change, sinceTrackChange: 0.5),
            "the previous track's sink line must not be applied to the new track"
        )
        XCTAssertFalse(
            TidalSwitchPolicy.lineMayBePreviousTrack(lineDate: change.addingTimeInterval(-1), trackChangeDate: change, sinceTrackChange: 0.5),
            "a line written just before a late MediaRemote event belongs to the new track"
        )
        XCTAssertFalse(
            TidalSwitchPolicy.lineMayBePreviousTrack(lineDate: change.addingTimeInterval(-180), trackChangeDate: change, sinceTrackChange: 5),
            "a same-rate gapless change writes no new line, so stop waiting for one"
        )
        XCTAssertFalse(
            TidalSwitchPolicy.lineMayBePreviousTrack(lineDate: change.addingTimeInterval(-180), trackChangeDate: nil, sinceTrackChange: .infinity)
        )
    }

    func testTidalSinkLineUsesFastGate() {
        let policy = RateSwitchingPolicy.gatePolicy(for: .tidalPlayerLog)

        XCTAssertEqual(policy.boundary, 0)
        XCTAssertLessThan(policy.lockedOverride, 1)
    }

    // MARK: - Fork change: All Apps survives a restart

    func testAllAppsMonitoringRoundTripsThroughStorage() {
        let stored = PlayerProfile.storedMonitoredValue(for: nil)

        XCTAssertNil(
            PlayerProfile.monitoredBundleIdentifier(fromStored: stored),
            "All Apps must read back as All Apps, not fall back to the registered Apple Music default"
        )
    }

    func testSpecificMonitoredSourceRoundTripsThroughStorage() {
        let stored = PlayerProfile.storedMonitoredValue(for: PlayerProfile.tidal.bundleIdentifier)

        XCTAssertEqual(PlayerProfile.monitoredBundleIdentifier(fromStored: stored), "com.tidal.desktop")
    }

    func testAllAppsSurvivesRelaunchWithAppleMusicRegisteredAsDefault() throws {
        let suiteName = "RateSyncTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "monitored"
        defaults.register(defaults: [key: PlayerProfile.appleMusic.bundleIdentifier])

        // Fresh install: the registered default applies.
        XCTAssertEqual(
            PlayerProfile.monitoredBundleIdentifier(fromStored: defaults.string(forKey: key)),
            PlayerProfile.appleMusic.bundleIdentifier
        )

        defaults.set(PlayerProfile.storedMonitoredValue(for: nil), forKey: key)

        XCTAssertNil(PlayerProfile.monitoredBundleIdentifier(fromStored: defaults.string(forKey: key)))
    }
}
