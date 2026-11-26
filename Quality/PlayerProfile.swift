import Foundation

struct PlayerProfile: Equatable, Identifiable {
    enum FormatDetection: Equatable {
        case mediaRemoteThenLogs
        case audioQueueLogs
        /// Fork change: the player's own text log file (TIDAL's player.log).
        case tidalPlayerLog
    }

    let bundleIdentifier: String
    let localizationKey: String
    let processName: String
    let formatDetection: FormatDetection
    let fallbackSampleRate: Double?

    var displayName: String { localizationKey }

    var id: String { bundleIdentifier }

    static let appleMusic = PlayerProfile(
        bundleIdentifier: "com.apple.Music",
        localizationKey: "Apple Music",
        processName: "Music",
        formatDetection: .mediaRemoteThenLogs,
        fallbackSampleRate: nil
    )
    static let spotify = PlayerProfile(
        bundleIdentifier: "com.spotify.client",
        localizationKey: "Spotify",
        processName: "Spotify",
        formatDetection: .mediaRemoteThenLogs,
        fallbackSampleRate: 44_100
    )
    static let neteaseMusic = PlayerProfile(
        bundleIdentifier: "com.netease.163music",
        localizationKey: "NetEase Music",
        processName: "NeteaseMusic",
        formatDetection: .audioQueueLogs,
        fallbackSampleRate: nil
    )
    static let qqMusic = PlayerProfile(
        bundleIdentifier: "com.tencent.QQMusicMac",
        localizationKey: "QQ Music",
        processName: "QQMusic",
        formatDetection: .audioQueueLogs,
        fallbackSampleRate: nil
    )

    /// Fork change: TIDAL reports no format via MediaRemote or the unified
    /// log; see TidalPlayerLog.swift.
    static let tidal = PlayerProfile(
        bundleIdentifier: "com.tidal.desktop",
        localizationKey: "TIDAL",
        processName: "TIDAL",
        formatDetection: .tidalPlayerLog,
        fallbackSampleRate: nil
    )

    static let monitoringSources = [appleMusic, spotify, neteaseMusic, qqMusic, tidal]

    /// Default takeover order used when the user selects "All Apps".
    /// Keeping Apple Music first preserves the behaviour users already had
    /// before multi-player arbitration was introduced.
    static let defaultPriorityBundleIdentifiers = monitoringSources.map(\.bundleIdentifier)

    static func normalizedPriority(_ bundleIdentifiers: [String]) -> [String] {
        var result: [String] = []
        for identifier in bundleIdentifiers {
            guard monitoringSources.contains(where: { $0.bundleIdentifier == identifier }),
                  !result.contains(identifier) else {
                continue
            }
            result.append(identifier)
        }

        for identifier in defaultPriorityBundleIdentifiers where !result.contains(identifier) {
            result.append(identifier)
        }
        return result
    }

    /// Fork change: how the monitored source is stored in UserDefaults.
    /// `nil` (All Apps) used to be stored by REMOVING the key, which made the
    /// registered default - Apple Music - come back on the next launch, so
    /// All Apps never survived a restart. It is now stored as this explicit
    /// value instead; a missing key still means the default (Apple Music).
    static let allAppsStoredValue = ""

    static func storedMonitoredValue(for bundleIdentifier: String?) -> String {
        bundleIdentifier ?? allAppsStoredValue
    }

    static func monitoredBundleIdentifier(fromStored stored: String?) -> String? {
        guard let stored, stored != allAppsStoredValue else { return nil }
        return stored
    }

    static func profile(for bundleIdentifier: String?) -> PlayerProfile? {
        monitoringSources.first { $0.bundleIdentifier == bundleIdentifier }
    }

    static func bundleIdentifier(forProcessName processName: String) -> String? {
        monitoringSources.first { $0.processName == processName }?.bundleIdentifier
    }
}
