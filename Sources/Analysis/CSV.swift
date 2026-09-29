import Foundation

/// The one CSV writer behind every export: pairwise analysis, the whole-history file, and the
/// per-source file offered before a device is removed.
///
/// Two exporters used to keep their own copies, and only one of them neutralised
/// spreadsheet formulas, so a device advertising itself as `=HYPERLINK(...)` became a live
/// formula in the whole-history file. Having one implementation is what keeps that from
/// drifting back.
enum CSV {

    /// Quotes a field when RFC 4180 requires it.
    ///
    /// The scan is over unicode scalars rather than `Character`s: Swift merges CR LF into
    /// one grapheme cluster, so `field.contains("\r")` is false for "a\r\nb" and the raw
    /// line break would be written unquoted, splitting one record into two.
    static func escape(_ field: String) -> String {
        let needsQuoting = field.unicodeScalars.contains { scalar in
            scalar == "," || scalar == "\"" || scalar == "\r" || scalar == "\n"
        }
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Makes free-form metadata literal in spreadsheet applications, before `escape` runs.
    ///
    /// Source names and models come from Bluetooth advertisements, Device Information
    /// characteristics, and HealthKit writers, all of which a nearby device or another app
    /// controls. A cell that begins with `=`, `+`, `-`, or `@` is a formula when the file is
    /// opened. A leading apostrophe is the portable spreadsheet convention for text; it stays
    /// part of the CSV cell rather than relying on a viewer-specific formula policy.
    /// Non-record control characters are replaced with spaces so the metadata cannot make the
    /// file non-conforming even when a peripheral or writer supplies a tab or C0/C1 byte.
    static func spreadsheetSafe(_ field: String) -> String {
        let sanitized = field.unicodeScalars.map { scalar -> String in
            if scalar == "\r" || scalar == "\n" {
                return String(scalar)
            }
            return CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()

        for scalar in sanitized.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            switch scalar {
            case "=", "+", "-", "@":
                return "'" + sanitized
            default:
                return sanitized
            }
        }
        return sanitized
    }
}
