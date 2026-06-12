import Foundation

/// Cleans up the messy genre entities Jellyfin inherits from file tags:
/// - one entity holding several genres ("Rock; Pop", "Folk/Rock", "Pop, Indie")
/// - ID3v1 lookalikes/misspellings ("AlternRock", "Psychadelic")
/// - case/punctuation variants ("Hip Hop" / "Hip-Hop" / "HIP HOP")
/// - junk numeric entries ("13", "(13)") — unmapped ID3v1 genre codes
///
/// The UI shows the cleaned names; queries still use the RAW entity names the
/// cleaned name was derived from, so nothing on the server has to change.
public enum GenreCleaner {

    /// Split a raw genre entity on the common multi-genre separators.
    public static func split(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ";,/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Canonical display name for one split part, or nil for junk.
    /// Strips an ID3 "(nn)" prefix ("(13)Pop" → "Pop"), drops pure-number
    /// entries, and maps known aliases to one spelling.
    public static func canonical(_ part: String) -> String? {
        var s = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^\(\d+\)"#, options: .regularExpression) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        guard !s.isEmpty else { return nil }
        if s.range(of: #"^\d+$"#, options: .regularExpression) != nil { return nil }
        if let alias = aliases[key(s)] { return alias }
        return s
    }

    /// Normalized merge key: lowercased alphanumerics only — "Hip-Hop",
    /// "Hip Hop" and "HIPHOP" all share a key and collapse to one entry.
    public static func key(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Pick the nicer display name between two variants sharing a key —
    /// prefer spaced, mixed-case, capitalised spellings over mashed/ALLCAPS.
    public static func betterDisplay(_ a: String, _ b: String) -> String {
        func score(_ s: String) -> Int {
            var v = 0
            if s.contains(" ") { v += 4 }
            if s != s.uppercased() { v += 2 }
            if s.first?.isUppercase == true { v += 1 }
            return v
        }
        let sa = score(a), sb = score(b)
        if sa != sb { return sa > sb ? a : b }
        if a.count != b.count { return a.count > b.count ? a : b }
        return min(a, b)
    }

    /// Collapse raw genre entities into cleaned display genres, each carrying
    /// the raw entity names it came from (for exact-match server queries).
    public static func displayGenres(from raw: [String]) -> [(name: String, matches: [String])] {
        var byKey: [String: (display: String, matches: Set<String>)] = [:]
        for entity in raw {
            for part in split(entity) {
                guard let canon = canonical(part) else { continue }
                let k = key(canon)
                guard !k.isEmpty else { continue }
                if var e = byKey[k] {
                    e.display = betterDisplay(e.display, canon)
                    e.matches.insert(entity)
                    byKey[k] = e
                } else {
                    byKey[k] = (canon, [entity])
                }
            }
        }
        return byKey.values
            .map { (name: $0.display, matches: Array($0.matches).sorted()) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Known alias spellings → one canonical name, keyed by `key(_:)`.
    /// Deliberately conservative: only merges that are unambiguous.
    private static let aliases: [String: String] = [
        // ID3v1 oddities
        "alternrock": "Alternative Rock",
        "altrock": "Alternative Rock",
        "alternativerock": "Alternative Rock",
        "psychadelic": "Psychedelic",
        "psychadelicrock": "Psychedelic Rock",
        // Spelling/punctuation families
        "hiphop": "Hip-Hop",
        "rb": "R&B",
        "rnb": "R&B",
        "rhythmandblues": "R&B",
        "rhythmblues": "R&B",
        "synthpop": "Synth-Pop",
        "lofi": "Lo-Fi",
        "drumbass": "Drum & Bass",
        "drumnbass": "Drum & Bass",
        "drumandbass": "Drum & Bass",
        "dnb": "Drum & Bass",
        "rocknroll": "Rock & Roll",
        "rockandroll": "Rock & Roll",
        "rockroll": "Rock & Roll",
        "progrock": "Progressive Rock",
        "progressiverock": "Progressive Rock",
        "soundtracks": "Soundtrack",
        "singersongwriter": "Singer-Songwriter"
    ]
}
