import AppKit

/// The fonts the editor can use. The viewport measures columns by a single
/// character width, so only fixed-pitch families are offered.
enum EditorFont {

    /// The installed fixed-pitch font families, sorted by name.
    static func monospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter(isMonospaced)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The regular face of `family` at `size`, or the system monospaced font
    /// when `family` is nil or no longer installed.
    static func font(family: String?, size: CGFloat) -> NSFont {
        var result = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if let family,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size),
           font.isFixedPitch {
            result = font
        }
        return result
    }

    /// The bold face of `font`, or `font` itself when it has none.
    static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func isMonospaced(_ family: String) -> Bool {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch == true
    }
}
