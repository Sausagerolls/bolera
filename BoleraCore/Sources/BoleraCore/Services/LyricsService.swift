import Foundation

public struct LyricsLine: Identifiable, Hashable {
    public let id = UUID()
    public let timestamp: TimeInterval?
    public let text: String

    public init(timestamp: TimeInterval?, text: String) {
        self.timestamp = timestamp
        self.text = text
    }
}

public struct Lyrics: Equatable {
    public let lines: [LyricsLine]
    public var isSynced: Bool { lines.contains { $0.timestamp != nil } }
    public var isEmpty: Bool { lines.isEmpty }

    public static let empty = Lyrics(lines: [])

    public init(lines: [LyricsLine]) {
        self.lines = lines
    }
}

public enum LyricsParser {
    /// Parses a `.lrc` lyrics file. Lines without timestamps become unsynced lines.
    public static func parseLRC(_ text: String) -> Lyrics {
        var out: [LyricsLine] = []
        // Matches one or more [mm:ss.xx] timestamps followed by lyric text.
        let timestampPattern = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,3}))?\\]", options: [])
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let regex = timestampPattern else { continue }
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                out.append(LyricsLine(timestamp: nil, text: line))
                continue
            }
            let lastEnd = matches.last!.range.location + matches.last!.range.length
            let body = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                let frac: Double
                if m.range(at: 3).location != NSNotFound {
                    let s = ns.substring(with: m.range(at: 3))
                    let v = Double(s) ?? 0
                    frac = v / pow(10.0, Double(s.count))
                } else { frac = 0 }
                let t = minutes * 60 + seconds + frac
                out.append(LyricsLine(timestamp: t, text: body))
            }
        }
        return Lyrics(lines: out.sorted { ($0.timestamp ?? -1) < ($1.timestamp ?? -1) })
    }
}

// MARK: - JellyfinClient extension

private struct JellyfinLyricsResponse: Decodable {
    let Lyrics: [Line]?
    struct Line: Decodable {
        let Text: String
        let Start: Int64?
    }
}

public extension JellyfinClient {
    func lyrics(for itemId: String) async throws -> Lyrics {
        let url = baseURL
            .appendingPathComponent("Audio/\(itemId)/Lyrics")
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(auth.authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return .empty
        }
        if let decoded = try? JSONDecoder().decode(JellyfinLyricsResponse.self, from: data),
           let lines = decoded.Lyrics, !lines.isEmpty {
            return Lyrics(lines: lines.map {
                let t: TimeInterval? = $0.Start.map { Double($0) / 10_000_000 }
                return LyricsLine(timestamp: t, text: $0.Text)
            })
        }
        // Fallback: server returned plain text (possibly LRC).
        if let text = String(data: data, encoding: .utf8) {
            return LyricsParser.parseLRC(text)
        }
        return .empty
    }
}
