import Foundation

/// Bluetooth addresses are stored and sent as lowercase dashes: `4c-87-5d-9e-2c-fa`.
/// IOBluetooth wants the same bytes with uppercase dashes.
enum BluetoothAddress {
    static func normalize(_ raw: String) -> String {
        let pieces = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0 == ":" || $0 == "-" || $0 == " " }
            .map { $0.lowercased() }
        guard pieces.count == 6 else { return "" }
        for piece in pieces {
            guard piece.count == 2, UInt8(piece, radix: 16) != nil else { return "" }
        }
        return pieces.joined(separator: "-")
    }

    static func dashedUpper(_ raw: String) -> String {
        normalize(raw).uppercased()
    }

    /// First MAC address embedded in a CoreAudio UID or device name.
    static func first(in text: String) -> String? {
        let pattern = "[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        let found = normalize(String(text[swiftRange]))
        return found.isEmpty ? nil : found
    }
}
