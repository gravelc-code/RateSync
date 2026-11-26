//
//  TidalPlayerLog.swift
//  RateSync
//
//  Fork change (not in upstream BiKing567/RateSync): TIDAL support.
//
//  The TIDAL desktop app reports no audio format through MediaRemote and
//  writes nothing useful to the unified log. Its native player helper
//  (TIDALPlayer.app) does keep a plain text log, and writes one line each
//  time it opens its CoreAudio output for a track:
//
//    [2026-11-26 10:38:54.782] [tisoc] [debug] [pcm_sink_coreaudio.cpp:35] CoreaudioSink::open, rate: 96000, type: int24
//
//  `rate` is the decoded stream's sample rate. In shared (non-exclusive)
//  mode TIDAL hands that to CoreAudio as-is and CoreAudio resamples it to
//  the device's current rate, so this line is what the device should be
//  switched to.
//
//  TIDAL only opens the sink for the track it is about to PLAY: a
//  `media.preload` of the next track creates a decoder but no sink. So,
//  unlike Apple Music's decoder lines, the newest sink line always belongs
//  to the playing track (or, for a moment after a track change, to the
//  previous one - which is then the device's current rate and a no-op).

import Foundation

struct TidalSinkFormat: Equatable {
    let sampleRate: Double
    let bitDepth: Int
    let date: Date
}

struct TidalPlayerSnapshot: Equatable {
    let newestSink: TidalSinkFormat?
    /// True only when TIDAL's newest logged playback state is "active".
    let isPlaying: Bool
}

enum TidalPlayerLog {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TIDAL/player.log")

    /// Only the end of the file is read: the newest sink line is all that
    /// matters, and the log grows by a few hundred KB per listening session.
    static let tailBytes = 256 * 1024

    private static let marker = "CoreaudioSink::open, rate: "

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// The newest sink format in `url`, or nil when the file is missing,
    /// unreadable or holds no sink line.
    static func newestSinkFormat(at url: URL = defaultURL) -> TidalSinkFormat? {
        guard let text = readTail(of: url) else { return nil }
        return parse(text).last
    }

    /// The newest sink format plus whether TIDAL is playing right now, from
    /// one read of `url`. Nil when the file is missing or unreadable.
    static func snapshot(at url: URL = defaultURL) -> TidalPlayerSnapshot? {
        guard let text = readTail(of: url) else { return nil }
        return parseSnapshot(text)
    }

    static func parseSnapshot(_ text: String) -> TidalPlayerSnapshot {
        var sink: TidalSinkFormat?
        var state: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line)
            if let format = parseLine(line) {
                sink = format
            } else if let newState = playbackState(inLine: line) {
                state = newState
            }
        }
        return TidalPlayerSnapshot(newestSink: sink, isPlaying: state == "active")
    }

    private static let stateMarker = "\"signal\": \"media.state\", \"state\": \""

    /// TIDAL logs every playback state change, e.g.
    /// `SIGNAL: {"signal": "media.state", "state": "active", "url": ...}`.
    /// Seen states: active, paused, stopped, completed.
    static func playbackState(inLine line: String) -> String? {
        guard let start = line.range(of: stateMarker)?.upperBound,
              let end = line[start...].firstIndex(of: "\"") else {
            return nil
        }
        return String(line[start..<end])
    }

    /// All sink formats in `text`, oldest first.
    static func parse(_ text: String) -> [TidalSinkFormat] {
        text.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ line: String) -> TidalSinkFormat? {
        guard let markerRange = line.range(of: marker) else { return nil }

        let afterMarker = line[markerRange.upperBound...]
        let rateDigits = afterMarker.prefix(while: \.isNumber)
        guard let sampleRate = Double(rateDigits), sampleRate > 0 else { return nil }

        guard line.hasPrefix("["),
              let closing = line.firstIndex(of: "]"),
              let date = timestampFormatter.date(from: String(line[line.index(after: line.startIndex)..<closing])) else {
            return nil
        }

        var bitDepth = 24
        if let typeRange = afterMarker.range(of: "type: ") {
            let type = afterMarker[typeRange.upperBound...].prefix(while: { $0.isLetter || $0.isNumber })
            bitDepth = Self.bitDepth(forSampleType: String(type)) ?? bitDepth
        }
        return TidalSinkFormat(sampleRate: sampleRate, bitDepth: bitDepth, date: date)
    }

    /// "int16" -> 16, "int24" -> 24, "float32" -> 32.
    static func bitDepth(forSampleType type: String) -> Int? {
        let digits = type.drop(while: { !$0.isNumber })
        guard let bits = Int(digits), bits > 0 else { return nil }
        return bits
    }

    private static func readTail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else {
            return nil
        }
        // A tail cut mid-character must not make the whole read fail.
        return String(decoding: data, as: UTF8.self)
    }
}
