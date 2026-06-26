import Foundation

/// Builds the enriched, ASCII-only recording filename. Keeps the `VoiceDrop-`
/// prefix and `.m4a` suffix (the mining pipeline filters on those), and packs
/// readable context between them so a file is self-describing in a listing:
///
///   VoiceDrop-2026-06-18-143052-0m33s-Thu-Afternoon-Shanghai-Xuhui.m4a
///
/// Everything is ASCII (letters, digits, hyphens) — no spaces, no CJK, no
/// punctuation — so it round-trips cleanly through URLs, R2 keys and curl.
enum RecordingName {

    /// `place` is an already-clean ASCII tag like "Shanghai-Xuhui" (or nil).
    static func make(start: Date, duration: TimeInterval, place: String?) -> String {
        var parts = ["VoiceDrop", timestamp(start), durationTag(duration), weekday(start), period(start)]
        if let place, !place.isEmpty { parts.append(place) }
        return parts.joined(separator: "-") + ".m4a"
    }

    static func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: d)
    }

    /// Parse a `yyyy-MM-dd-HHmmss` stamp (a sessionTs) back to a Date — used to
    /// compute a photo's offset (seconds since the recording started).
    static func date(fromTimestamp ts: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: ts)
    }

    /// The R2 relative key for a scene photo: `photos/<sessionTs>/<offset>-<rand>.jpg`.
    /// - `sessionTs` groups every photo of one recording (correlation + cheap cleanup).
    /// - `offset` = seconds from the recording start to capture — this IS "第几秒加进来"
    ///   (absolute capture time is recoverable as sessionTs + offset, so nothing is lost),
    ///   and it's far shorter than the old absolute `yyyy-MM-dd-HHmmss` capture stamp.
    /// - a 3-char base36 tail makes the key unique even when several photos land in the
    ///   SAME offset-second (e.g. a 9-photo album import, whose callbacks fire near-
    ///   simultaneously) — the old seconds-only name silently overwrote and lost photos.
    static func photoKey(sessionTs: String, offset: Int) -> String {
        "photos/\(sessionTs)/\(max(0, offset))-\(randomTag()).jpg"
    }

    /// `count` random base36 chars (0-9a-z). 3 → 46,656 combos: even 9 photos sharing
    /// one offset-second collide with ~0.08% probability — comfortably safe, still tiny.
    static func randomTag(_ count: Int = 3) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<count).map { _ in alphabet.randomElement()! })
    }

    static func durationTag(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        return "\(total / 60)m\(total % 60)s"
    }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func weekday(_ d: Date) -> String {
        let wd = Calendar.current.component(.weekday, from: d)   // 1 = Sunday
        return weekdays[(wd - 1) % 7]
    }

    static func period(_ d: Date) -> String {
        switch Calendar.current.component(.hour, from: d) {
        case 5..<9:   return "EarlyMorning"
        case 9..<12:  return "Morning"
        case 12..<14: return "Noon"
        case 14..<18: return "Afternoon"
        case 18..<20: return "Evening"
        case 20..<23: return "Night"
        default:      return "LateNight"
        }
    }
}
