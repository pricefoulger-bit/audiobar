import Foundation

/// Peer host and shared secret.
///
/// `install.sh` writes `~/Library/Application Support/AudioBar/config.json`:
/// `{"peerHost":"mac-mini","secret":"..."}`.
/// The same secret is mirrored to `secret` so a later launch still has it if the
/// JSON is missing. Both Macs must use the same secret.
struct AppConfig: Equatable {
    var peerHost: String
    var secret: String

    static let port: UInt16 = 47653
    static let secretHeader = "X-AudioBar-Secret"

    static func load() -> AppConfig {
        let directory = supportDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        let secretURL = directory.appendingPathComponent("secret")

        var peerHost = ""
        var secret = ""
        if let data = try? Data(contentsOf: configURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            peerHost = sanitizedHost(object["peerHost"] as? String ?? "")
            secret = sanitizedSecret(object["secret"] as? String ?? "")
        }
        if secret.isEmpty, let stored = try? String(contentsOf: secretURL, encoding: .utf8) {
            secret = sanitizedSecret(stored)
        }
        if secret.isEmpty {
            secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            NSLog("%@", "AudioBar generated a secret. Pass the same secret to install.sh on the other Mac.")
        }
        if let existing = try? String(contentsOf: secretURL, encoding: .utf8),
           sanitizedSecret(existing) == secret {
            // already on disk
        } else if let data = secret.data(using: .utf8) {
            try? data.write(to: secretURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
        }
        return AppConfig(peerHost: peerHost, secret: secret)
    }

    private static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AudioBar", isDirectory: true)
    }

    private static func sanitizedHost(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedSecret(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline && $0 != "\r" }
    }
}
