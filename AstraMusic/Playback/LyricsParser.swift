import Foundation

/// Turns Kugou lyric payloads into timed, display-ready lines.
///
/// Two formats arrive in practice: KRC (word-level, with per-character timings)
/// and plain LRC. Both are flattened to one `LyricLine` per visible line — the
/// UI scrolls by line, so character timings are discarded rather than modelled.
enum LyricsParser {
    /// Parses the `decodeContent` string from `/lyric?decode=true`.
    ///
    /// Tries KRC first and falls back to LRC: some tracks return LRC text even
    /// when the request asked for KRC, and the KRC parser simply finds nothing
    /// to parse in that case.
    static func parseDecodedLyric(_ source: String) -> [LyricLine] {
        let krc = parseKRCPlain(source)
        return krc.isEmpty ? parse(source) : krc
    }

    /// Line-level KRC (`[startMs,duration]<offset,dur,?>text`). Character timings are flattened.
    ///
    /// Only the start milliseconds and the text survive; `<...>` word tags are
    /// stripped and untimed/empty lines are dropped. Times are clamped at zero
    /// because leading metadata can carry a negative offset.
    static func parseKRCPlain(_ source: String) -> [LyricLine] {
        var pairs: [(TimeInterval, String)] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.first == "[", let close = line.firstIndex(of: "]") else { continue }
            let inner = line[line.index(after: line.startIndex)..<close]
            guard inner.contains(",") else { continue }
            let startPart = inner.split(separator: ",").first
            guard let startPart, let startMs = Double(startPart) else { continue }
            let body = String(line[line.index(after: close)...])
            let text = stripKRCTags(body).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            pairs.append((max(0, startMs / 1000), text))
        }
        return pairs.enumerated().map { index, pair in
            LyricLine(id: index, time: pair.0, text: pair.1)
        }
    }

    /// Removes KRC's angle-bracket word tags, keeping only the displayed text.
    /// Handles adjacent tags (`<0,100,0>你<100,100,0>好`) by skipping to each `>`.
    private static func stripKRCTags(_ body: String) -> String {
        var text = ""
        var index = body.startIndex
        while index < body.endIndex {
            if body[index] == "<", let end = body[index...].firstIndex(of: ">") {
                index = body.index(after: end)
            } else {
                text.append(body[index])
                index = body.index(after: index)
            }
        }
        return text
    }

    /// Parses standard LRC into timed lines. Metadata tags are ignored; `[offset:±ms]` is applied.
    ///
    /// A line may carry several timestamps (repeated chorus), which expands into
    /// one entry each, so the result is sorted afterwards rather than relying on
    /// source order. The `[offset:]` tag is taken from wherever it appears, so it
    /// affects only the lines that follow it.
    static func parse(_ source: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var pairs: [(TimeInterval, String)] = []

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let value = offsetValue(in: line) {
                offset = value
                continue
            }
            if isMetadata(line) { continue }

            let extracted = extractTimes(from: line)
            let text = extracted.text.trimmingCharacters(in: .whitespaces)
            guard !extracted.times.isEmpty, !text.isEmpty else { continue }
            for time in extracted.times {
                pairs.append((max(0, time + offset), text))
            }
        }

        pairs.sort { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }

        return pairs.enumerated().map { index, pair in
            LyricLine(id: index, time: pair.0, text: pair.1)
        }
    }

    /// Reads `[offset:±milliseconds]` and converts it to seconds.
    private static func offsetValue(in line: String) -> TimeInterval? {
        let prefix = "[offset:"
        guard line.lowercased().hasPrefix(prefix), line.hasSuffix("]") else { return nil }
        let raw = String(line.dropFirst(prefix.count).dropLast())
            .trimmingCharacters(in: .whitespaces)
        guard let milliseconds = Double(raw) else { return nil }
        return milliseconds / 1000
    }

    /// True for bracketed tags that are metadata rather than timestamps:
    /// `[ti:…]`, `[ar:…]`, `[by:…]`. A real timestamp (`[00:12.34]`) contains
    /// only digits and punctuation, so "the key has a letter" is the test.
    private static func isMetadata(_ line: String) -> Bool {
        guard line.hasPrefix("["), line.hasSuffix("]") else { return false }
        let inner = line.dropFirst().dropLast()
        guard let colon = inner.firstIndex(of: ":") else { return false }
        let key = inner[..<colon]
        return key.contains { $0.isLetter }
    }

    /// Consumes leading `[mm:ss(.fff)]` tags and returns them plus the remaining
    /// text. Stops at the first bracket that is not a valid timestamp, which is
    /// what keeps `[00:01.00]` in a lyric body from being misread.
    private static func extractTimes(from line: String) -> (times: [TimeInterval], text: String) {
        var times: [TimeInterval] = []
        var remainder = Substring(line)
        while remainder.first == "[", let close = remainder.firstIndex(of: "]") {
            let inner = remainder[remainder.index(after: remainder.startIndex)..<close]
            if let time = parseTime(String(inner)) {
                times.append(time)
                remainder = remainder[remainder.index(after: close)...]
            } else {
                break
            }
        }
        return (times, String(remainder))
    }

    /// Parses `mm:ss` or `mm:ss.fff` into seconds, rejecting out-of-range values.
    private static func parseTime(_ tag: String) -> TimeInterval? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        let secondParts = parts[1].split(separator: ".", maxSplits: 1)
        guard let seconds = Int(secondParts[0]), (0..<60).contains(seconds) else { return nil }

        var value = TimeInterval(minutes * 60 + seconds)
        if secondParts.count == 2 {
            // Fractional digits are right-padded to milliseconds (`.5` is 500 ms,
            // not 5 ms) before being truncated to three digits.
            let fraction = String(secondParts[1])
            guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return nil }
            let padded = fraction.padding(toLength: 3, withPad: "0", startingAt: 0)
            let milliseconds = Double(padded.prefix(3)) ?? 0
            value += milliseconds / 1000
        }
        return value
    }
}
