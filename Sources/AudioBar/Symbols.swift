import AppKit

enum Symbols {
    static func image(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .medium,
        description: String? = nil
    ) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: description)
            ?? NSImage()
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = true
        return image
    }
}
